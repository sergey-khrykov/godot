using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;

using ConnectFlags = Godot.Object.ConnectFlags;

namespace Godot
{
    internal class SignalProcessor : IDisposable
    {

        public class Connection
        {
            public object Callback;
            public ConnectFlags Flags;
            public bool Processed;
            int References = 0;

            public Connection(object callback, ConnectFlags flags)
            {
                Callback = callback;
                Flags = flags;
                Processed = false;
                References = 1;
            }

            public void Reference()
            {
                References += 1;
                Flags = Flags | ConnectFlags.ReferenceCounted;
            }

            public bool Unreference()
            {
                References -= 1;
                return References <= 0;
            }

            public bool Deferred
            {
                get => (Flags & ConnectFlags.Deferred) > 0;
            }

            public bool Oneshot
            {
                get => (Flags & ConnectFlags.Oneshot) > 0;
            }

            public bool ReferenceCounted
            {
                get => (Flags & ConnectFlags.ReferenceCounted) > 0;
            }

        }

        struct DeferredCall
        {
            public SignalProcessor Processor;
            public object Callback;
            public object[] Args;
            public DeferredCall(SignalProcessor processor, object callback, object[] args)
            {
                Processor = processor;
                Callback = callback;
                Args = args;
            }
        }

        static int LastDeferredCallId = 0;
        static List<string> Names = new List<string>();
        static Dictionary<int, DeferredCall> DeferredCalls = new Dictionary<int, DeferredCall>();
        static Regex Pattern = new Regex("[A-Z]");

        public delegate void ProcessCallbackDelegate(object callback, object[] args);
        public delegate void CancelCallbackDelegate(object callback);
        public ProcessCallbackDelegate ProcessCallback;
        public CancelCallbackDelegate CancelCallback;
        int NameIndex;
        int FieldIndex;
        internal WeakReference<Godot.Object> Owner;
        bool InternalConnected = false;
        uint ProcessingLevel = 0;
        bool DisconnectionQueued = false;
        internal LinkedList<Connection> Connections = new LinkedList<Connection>();
        static string FieldToStringName(string fieldName)
        {
            string signalName = Pattern.Replace(fieldName, "_$0").ToLower();
            if (signalName.BeginsWith("_"))
            {
                return signalName.Substring(1);
            }
            else
            {
                return signalName;
            }
        }
        public static T FetchValue<T>(object[] args, int idx)
        {
            if (idx >= args.Length || args[idx] == null)
            {
                return default(T);
            }
            else
            {
                return (T)args[idx];
            }
        }

        public static void ProcessSignal(Godot.Object owner, int fieldIndex, object[] args)
        {
            owner.SignalProcessors[fieldIndex].IterateTargets(args);
        }
        public static void ProcessDeferredCall(int id)
        {
            DeferredCall call;
            if (DeferredCalls.TryGetValue(id, out call))
            {
                DeferredCalls.Remove(id);
                call.Processor.ProcessCallback(call.Callback, call.Args);
            }
        }
        public static void InjectTo(Godot.Object pOwner)
        {
            var idx = -1;
            var fields = pOwner.GetType().GetFields(BindingFlags.FlattenHierarchy | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
            foreach (var field in fields)
            {
                idx++;
                var boxedSignal = field.GetValue(pOwner) as ISignalField;
                if (boxedSignal == null || boxedSignal.Processor != null)
                {
                    continue;
                }
                // skip lazy fields generated by engine
                if (Attribute.IsDefined(field, typeof(ManagedSignalAttribute)))
                {
                    continue;
                }
                var signalName = FieldToStringName(field.Name);
                var processor = new SignalProcessor(pOwner, signalName, pOwner.SignalProcessors.Count);
                pOwner.SignalProcessors.Add(processor);
                boxedSignal.Processor = processor;
                processor.ProcessCallback = boxedSignal.ProcessCallback;
                processor.CancelCallback = boxedSignal.CancelCallback;
                field.SetValue(pOwner, boxedSignal);
            }
        }
        public static void InjectTo<T>(Godot.Object pOwner, string signalName, ref T signal) where T : ISignalField
        {
            var processor = new SignalProcessor(pOwner, signalName, pOwner.SignalProcessors.Count);
            pOwner.SignalProcessors.Add(processor);
            signal.Processor = processor;
            processor.ProcessCallback = signal.ProcessCallback;
            processor.CancelCallback = signal.CancelCallback;
        }
        public SignalProcessor(Godot.Object pOwner, string pSignalName, int pFieldIndex)
        {
            Owner = new WeakReference<Godot.Object>(pOwner, false);
            FieldIndex = pFieldIndex;
            NameIndex = Names.IndexOf(pSignalName);
            if (NameIndex < 0)
            {
                NameIndex = Names.Count;
                Names.Add(pSignalName);
            }
        }
        String SignalName { get { return Names[NameIndex]; } }
        public void Connect(object callback, ConnectFlags flags, bool checkForDuplicates = true)
        {
            ConnectInternal();
            // no need to check awaiters, they are unique
            if (!checkForDuplicates)
            {
                Connections.AddLast(new Connection(callback, flags));
                return;
            }

            var connection = Connections.FirstOrDefault(c => c.Callback.Equals(callback) && !c.Processed);
            if (connection == null)
            {
                Connections.AddLast(new Connection(callback, flags));
                return;
            }

            if (connection.ReferenceCounted || (flags & ConnectFlags.ReferenceCounted) > 0)
            {
                connection.Reference();
                return;
            }

            Godot.Object owner;
            String methodRepr;
            if (callback is Delegate dlg)
            {
                methodRepr = $"{dlg.Method.DeclaringType.Name}.{dlg.Method.Name}";
            }
            else
            {
                methodRepr = $"{callback}";
            }
            if (Owner.TryGetTarget(out owner))
            {
                GD.PushError($"Signal '{SignalName}' is already connected to {methodRepr} in object {owner}.");
            }
            else
            {
                GD.PushError($"Unable to connect signal '{SignalName}' to {methodRepr}: Object is gone.");
            }
        }

        public void Disconnect(object callback)
        {
            for (var item = Connections.First; item != null; item = item.Next)
            {
                var connection = item.Value;
                if (!connection.Callback.Equals(callback) || connection.Processed) continue;
                if (connection.ReferenceCounted)
                {
                    if (!connection.Unreference())
                    {
                        return;
                    }
                }
                if (ProcessingLevel > 0)
                {
                    connection.Processed = true;
                    DisconnectionQueued = true;
                }
                else
                {
                    Connections.Remove(item);
                    CancelCallback(connection.Callback);
                    if (Connections.First == null)
                    {
                        DisconnectInternal();
                    }
                    return;
                }
            }
        }
        public void DisconnectAll()
        {
            for (var item = Connections.First; item != null; item = item.Next)
            {
                var connection = item.Value;
                if (ProcessingLevel > 0)
                {
                    connection.Processed = true;
                }
                else
                {
                    CancelCallback(connection.Callback);
                    Connections.Remove(item);
                }
            }
            if (ProcessingLevel > 0)
            {
                DisconnectionQueued = true;
            }
            else
            {
                DisconnectInternal();
            }
        }

        public void IterateTargets(object[] args)
        {
            ProcessingLevel++;
            LinkedList<Connection> disconnections = new LinkedList<Connection>();
            var last = Connections.Last;
            var current = Connections.First;
            while (current != null)
            {
                var connection = current.Value;
                if (!connection.Processed)
                {
                    // process oneshot signals only once
                    if (connection.Oneshot && !connection.Processed)
                    {
                        connection.Processed = true;
                        disconnections.AddLast(connection);
                    }
                    if (connection.Deferred)
                    {
                        ProcessDeferred(connection.Callback, args);
                    }
                    else
                    {
                        ProcessCallback(connection.Callback, args);
                    }
                }
                if (current == last)
                {
                    break;
                }
                current = current.Next;
            }

            // deleting oneshot signals
            var disconnecting = disconnections.First;
            current = Connections.First;
            while (current != null && disconnecting != null)
            {
                var connection = current.Value;
                var disconnection = disconnecting.Value;
                var next = current.Next;
                if (connection.Callback.Equals(disconnection.Callback))
                {
                    Connections.Remove(current);
                    disconnecting = disconnecting.Next;
                }
                if (current == last)
                {
                    break;
                }
                current = next;
            }

            ProcessingLevel--;
            if (ProcessingLevel == 0 && DisconnectionQueued)
            {
                var item = Connections.First;
                while (item != null)
                {
                    var next = item.Next;
                    if (item.Value.Processed)
                    {
                        Connections.Remove(item);
                        CancelCallback(item.Value.Callback);
                    }
                    item = next;
                }
                DisconnectionQueued = false;
            }

            if (Connections.First == null)
            {
                DisconnectInternal();
            }
        }
        void ProcessDeferred(object callback, object[] args)
        {
            DeferredCalls[LastDeferredCallId] = new DeferredCall(this, callback, args);
            godot_icall_SignalProcessor_call_deferred(LastDeferredCallId);
            LastDeferredCallId++;
        }
        [MethodImpl(MethodImplOptions.InternalCall)]
        internal extern static void godot_icall_SignalProcessor_call_deferred(int id);

        public void Emit(object[] args)
        {
            Godot.Object owner;
            if (Owner.TryGetTarget(out owner)) owner.EmitSignal(SignalName, args);
        }
        void ConnectInternal()
        {
            if (!InternalConnected)
            {
                Godot.Object owner;
                if (Owner.TryGetTarget(out owner))
                    godot_icall_SignalProcessor_connect(Object.GetPtr(owner), SignalName, FieldIndex);
                InternalConnected = true;
            }
        }

        [MethodImpl(MethodImplOptions.InternalCall)]
        internal extern static Error godot_icall_SignalProcessor_connect(IntPtr target, string signal, int index);

        void DisconnectInternal()
        {
            Godot.Object owner;
            if (InternalConnected && Owner.TryGetTarget(out owner))
            {
                godot_icall_SignalProcessor_disconnect(Object.GetPtr(owner), SignalName);
                InternalConnected = false;
            }
        }

        [MethodImpl(MethodImplOptions.InternalCall)]
        internal extern static void godot_icall_SignalProcessor_disconnect(IntPtr target, string signal);


        public void Dispose()
        {
            DisconnectInternal();
        }
    }
}