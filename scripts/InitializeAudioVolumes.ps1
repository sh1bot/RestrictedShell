#requires -version 5.1

[CmdletBinding()]
param(
    [string]$IniPath = '',
    [string]$Section = 'AudioDefaults',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

if (-not $IniPath) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $IniPath = Join-Path (Split-Path -Parent $scriptDirectory) 'RestrictedShell.ini'
}

if (-not ('RestrictedShell.AudioPreset' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace RestrictedShell
{
    public enum EndpointFormFactor
    {
        RemoteNetworkDevice = 0,
        Speakers = 1,
        LineLevel = 2,
        Headphones = 3,
        Microphone = 4,
        Headset = 5,
        Handset = 6,
        UnknownDigitalPassthrough = 7,
        SPDIF = 8,
        DigitalAudioDisplayDevice = 9,
        UnknownFormFactor = 10
    }

    enum EDataFlow
    {
        eRender = 0,
        eCapture = 1,
        eAll = 2
    }

    enum ERole
    {
        eConsole = 0,
        eMultimedia = 1,
        eCommunications = 2
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;

        public PROPERTYKEY(string fmtid, uint pid)
        {
            this.fmtid = new Guid(fmtid);
            this.pid = pid;
        }
    }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
        [FieldOffset(8)] public uint uintValue;
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IMMDeviceCollection devices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);

        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);

        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr client);

        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport]
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig]
        int GetCount(out uint count);

        [PreserveSig]
        int Item(uint index, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, uint clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);

        [PreserveSig]
        int OpenPropertyStore(uint stgmAccess, out IPropertyStore properties);

        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);

        [PreserveSig]
        int GetState(out uint state);
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig]
        int GetCount(out uint count);

        [PreserveSig]
        int GetAt(uint index, out PROPERTYKEY key);

        [PreserveSig]
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);

        [PreserveSig]
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);

        [PreserveSig]
        int Commit();
    }

    [ComImport]
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig]
        int RegisterControlChangeNotify(IntPtr notify);

        [PreserveSig]
        int UnregisterControlChangeNotify(IntPtr notify);

        [PreserveSig]
        int GetChannelCount(out uint channelCount);

        [PreserveSig]
        int SetMasterVolumeLevel(float levelDb, IntPtr eventContext);

        [PreserveSig]
        int SetMasterVolumeLevelScalar(float level, IntPtr eventContext);
    }

    public static class AudioPreset
    {
        const uint DEVICE_STATE_ACTIVE = 0x00000001;
        const uint DEVICE_STATE_UNPLUGGED = 0x00000008;
        const uint STGM_READ = 0;
        const uint CLSCTX_ALL = 23;
        const ushort VT_UI4 = 19;
        const ushort VT_LPWSTR = 31;

        static readonly PROPERTYKEY PKEY_Device_FriendlyName =
            new PROPERTYKEY("A45C254E-DF1C-4EFD-8020-67D146A850E0", 14);

        static readonly PROPERTYKEY PKEY_AudioEndpoint_FormFactor =
            new PROPERTYKEY("1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E", 0);

        static readonly Guid IID_IAudioEndpointVolume =
            new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PROPVARIANT value);

        sealed class Endpoint
        {
            public string Id;
            public string Name;
            public uint State;
            public EndpointFormFactor FormFactor;
        }

        sealed class Defaults
        {
            public string Console;
            public string Multimedia;
            public string Communications;
        }

        static void ThrowIfFailed(int hr, string operation)
        {
            if (hr < 0)
                throw new COMException(operation + " failed.", hr);
        }

        static string GetDefaultId(IMMDeviceEnumerator enumerator, ERole role)
        {
            IMMDevice device = null;
            try
            {
                int hr = enumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, role, out device);
                if (hr < 0 || device == null)
                    return null;

                string id;
                ThrowIfFailed(device.GetId(out id), "IMMDevice.GetId");
                return id;
            }
            finally
            {
                if (device != null)
                    Marshal.ReleaseComObject(device);
            }
        }

        static string GetStringProperty(IPropertyStore store, PROPERTYKEY key)
        {
            PROPVARIANT value;
            int hr = store.GetValue(ref key, out value);
            if (hr < 0)
                return null;

            try
            {
                if (value.vt != VT_LPWSTR || value.pointerValue == IntPtr.Zero)
                    return null;

                return Marshal.PtrToStringUni(value.pointerValue);
            }
            finally
            {
                PropVariantClear(ref value);
            }
        }

        static uint GetUIntProperty(IPropertyStore store, PROPERTYKEY key, uint fallback)
        {
            PROPVARIANT value;
            int hr = store.GetValue(ref key, out value);
            if (hr < 0)
                return fallback;

            try
            {
                return value.vt == VT_UI4 ? value.uintValue : fallback;
            }
            finally
            {
                PropVariantClear(ref value);
            }
        }

        static List<Endpoint> Enumerate(IMMDeviceEnumerator enumerator)
        {
            IMMDeviceCollection collection = null;
            List<Endpoint> result = new List<Endpoint>();

            try
            {
                ThrowIfFailed(
                    enumerator.EnumAudioEndpoints(
                        EDataFlow.eRender,
                        DEVICE_STATE_ACTIVE | DEVICE_STATE_UNPLUGGED,
                        out collection),
                    "EnumAudioEndpoints");

                uint count;
                ThrowIfFailed(collection.GetCount(out count), "IMMDeviceCollection.GetCount");

                for (uint i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    IPropertyStore store = null;
                    try
                    {
                        ThrowIfFailed(collection.Item(i, out device), "IMMDeviceCollection.Item");

                        string id;
                        uint state;
                        ThrowIfFailed(device.GetId(out id), "IMMDevice.GetId");
                        ThrowIfFailed(device.GetState(out state), "IMMDevice.GetState");
                        ThrowIfFailed(device.OpenPropertyStore(STGM_READ, out store), "IMMDevice.OpenPropertyStore");

                        string name = GetStringProperty(store, PKEY_Device_FriendlyName);
                        uint formFactor = GetUIntProperty(
                            store,
                            PKEY_AudioEndpoint_FormFactor,
                            (uint)EndpointFormFactor.UnknownFormFactor);

                        result.Add(new Endpoint
                        {
                            Id = id,
                            Name = String.IsNullOrEmpty(name) ? id : name,
                            State = state,
                            FormFactor = (EndpointFormFactor)formFactor
                        });
                    }
                    finally
                    {
                        if (store != null)
                            Marshal.ReleaseComObject(store);
                        if (device != null)
                            Marshal.ReleaseComObject(device);
                    }
                }
            }
            finally
            {
                if (collection != null)
                    Marshal.ReleaseComObject(collection);
            }

            return result;
        }

        static bool IsPrivate(Endpoint endpoint)
        {
            return endpoint.FormFactor == EndpointFormFactor.Headphones ||
                   endpoint.FormFactor == EndpointFormFactor.Headset ||
                   endpoint.FormFactor == EndpointFormFactor.Handset;
        }

        static bool SameId(string a, string b)
        {
            return a != null && b != null &&
                String.Equals(a, b, StringComparison.OrdinalIgnoreCase);
        }

        static int DefaultBonus(Endpoint endpoint, Defaults defaults)
        {
            if (SameId(endpoint.Id, defaults.Multimedia)) return 3000;
            if (SameId(endpoint.Id, defaults.Console)) return 2500;
            if (SameId(endpoint.Id, defaults.Communications)) return 2000;
            return 0;
        }

        static int StateBonus(Endpoint endpoint)
        {
            return (endpoint.State & DEVICE_STATE_ACTIVE) != 0 ? 1000 : 0;
        }

        static int PublicFormFactorBonus(Endpoint endpoint)
        {
            switch (endpoint.FormFactor)
            {
                case EndpointFormFactor.Speakers: return 600;
                case EndpointFormFactor.LineLevel: return 500;
                case EndpointFormFactor.DigitalAudioDisplayDevice: return 400;
                case EndpointFormFactor.SPDIF: return 300;
                case EndpointFormFactor.UnknownDigitalPassthrough: return 200;
                case EndpointFormFactor.UnknownFormFactor: return 100;
                default: return 0;
            }
        }

        static int PrivateFormFactorBonus(Endpoint endpoint)
        {
            switch (endpoint.FormFactor)
            {
                case EndpointFormFactor.Headphones: return 300;
                case EndpointFormFactor.Headset: return 250;
                case EndpointFormFactor.Handset: return 200;
                default: return 0;
            }
        }

        static Endpoint ChoosePublic(List<Endpoint> endpoints, Defaults defaults)
        {
            Endpoint best = null;
            int bestScore = Int32.MinValue;

            foreach (Endpoint endpoint in endpoints)
            {
                if (IsPrivate(endpoint))
                    continue;

                int score = DefaultBonus(endpoint, defaults) +
                    StateBonus(endpoint) + PublicFormFactorBonus(endpoint);

                if (best == null || score > bestScore)
                {
                    best = endpoint;
                    bestScore = score;
                }
            }

            return best;
        }

        static Endpoint ChoosePrivate(List<Endpoint> endpoints, Defaults defaults, string excludedId)
        {
            Endpoint best = null;
            int bestScore = Int32.MinValue;

            foreach (Endpoint endpoint in endpoints)
            {
                if (!IsPrivate(endpoint) || SameId(endpoint.Id, excludedId))
                    continue;

                int score = DefaultBonus(endpoint, defaults) +
                    StateBonus(endpoint) + PrivateFormFactorBonus(endpoint);

                if (best == null || score > bestScore)
                {
                    best = endpoint;
                    bestScore = score;
                }
            }

            return best;
        }

        static Endpoint ChooseSafetyFallback(List<Endpoint> endpoints, Defaults defaults)
        {
            Endpoint best = null;
            int bestScore = Int32.MinValue;

            foreach (Endpoint endpoint in endpoints)
            {
                int score = DefaultBonus(endpoint, defaults) + StateBonus(endpoint);
                if (best == null || score > bestScore)
                {
                    best = endpoint;
                    bestScore = score;
                }
            }

            return best;
        }

        static void SetVolume(IMMDeviceEnumerator enumerator, Endpoint endpoint, int percent)
        {
            IMMDevice device = null;
            object activated = null;

            try
            {
                ThrowIfFailed(enumerator.GetDevice(endpoint.Id, out device), "IMMDeviceEnumerator.GetDevice");

                Guid iid = IID_IAudioEndpointVolume;
                ThrowIfFailed(
                    device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out activated),
                    "IMMDevice.Activate(IAudioEndpointVolume)");

                IAudioEndpointVolume volume = (IAudioEndpointVolume)activated;
                ThrowIfFailed(
                    volume.SetMasterVolumeLevelScalar(percent / 100.0f, IntPtr.Zero),
                    "SetMasterVolumeLevelScalar");
            }
            finally
            {
                if (activated != null && Marshal.IsComObject(activated))
                    Marshal.ReleaseComObject(activated);
                if (device != null)
                    Marshal.ReleaseComObject(device);
            }
        }

        static string Describe(Endpoint endpoint)
        {
            return endpoint.Name + " (" + endpoint.FormFactor.ToString() + ")";
        }

        public static string[] Apply(int publicVolume, int privateVolume)
        {
            if (publicVolume < 0 || publicVolume > 100)
                throw new ArgumentOutOfRangeException("publicVolume");
            if (privateVolume < 0 || privateVolume > 100)
                throw new ArgumentOutOfRangeException("privateVolume");

            IMMDeviceEnumerator enumerator = null;
            List<string> messages = new List<string>();

            try
            {
                enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();

                Defaults defaults = new Defaults
                {
                    Console = GetDefaultId(enumerator, ERole.eConsole),
                    Multimedia = GetDefaultId(enumerator, ERole.eMultimedia),
                    Communications = GetDefaultId(enumerator, ERole.eCommunications)
                };

                List<Endpoint> endpoints = Enumerate(enumerator);
                if (endpoints.Count == 0)
                    throw new InvalidOperationException("No active or unplugged render endpoints were found.");

                Endpoint publicEndpoint = ChoosePublic(endpoints, defaults);
                bool usedSafetyFallback = false;

                if (publicEndpoint == null)
                {
                    publicEndpoint = ChooseSafetyFallback(endpoints, defaults);
                    usedSafetyFallback = true;
                }

                if (publicEndpoint == null)
                    throw new InvalidOperationException("Could not identify a public audio fallback endpoint.");

                SetVolume(enumerator, publicEndpoint, publicVolume);

                if (usedSafetyFallback)
                    messages.Add("No distinct public endpoint was identifiable; treating " +
                        Describe(publicEndpoint) + " as public for safety.");

                messages.Add("Public: " + Describe(publicEndpoint) + " -> " + publicVolume + "%");

                Endpoint privateEndpoint = ChoosePrivate(endpoints, defaults, publicEndpoint.Id);
                if (privateEndpoint != null)
                {
                    try
                    {
                        SetVolume(enumerator, privateEndpoint, privateVolume);
                        messages.Add("Private: " + Describe(privateEndpoint) + " -> " + privateVolume + "%");
                    }
                    catch (Exception ex)
                    {
                        messages.Add("Warning: could not preset private endpoint " +
                            Describe(privateEndpoint) + ": " + ex.Message);
                    }
                }
                else
                {
                    messages.Add("No distinct private headphone/headset endpoint was found.");
                }

                return messages.ToArray();
            }
            finally
            {
                if (enumerator != null)
                    Marshal.ReleaseComObject(enumerator);
            }
        }
    }
}
'@
}

if ($ValidateOnly) {
    Write-Output 'InitializeAudioVolumes.ps1 compiled successfully.'
    exit 0
}

function Read-IniSection {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INI file not found: $Path"
    }

    $values = @{}
    $inSection = $false

    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = $line.Trim()

        if ($text -match '^\[(.+)\]$') {
            $inSection = $matches[1] -eq $Name
            continue
        }

        if ($inSection -and $text -match '^([^;#][^=]*)=(.*)$') {
            $values[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    return $values
}

function Get-VolumeSetting {
    param(
        [Parameter(Mandatory = $true)]$Values,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Values.ContainsKey($Name)) {
        throw "Missing [$Section] $Name in $IniPath"
    }

    $value = 0
    if (-not [int]::TryParse($Values[$Name], [ref]$value) -or $value -lt 0 -or $value -gt 100) {
        throw "[$Section] $Name must be an integer from 0 to 100."
    }

    return $value
}

try {
    $settings = Read-IniSection -Path $IniPath -Name $Section
    $publicVolume = Get-VolumeSetting -Values $settings -Name 'PublicVolume'
    $privateVolume = Get-VolumeSetting -Values $settings -Name 'PrivateVolume'

    [RestrictedShell.AudioPreset]::Apply($publicVolume, $privateVolume) |
        ForEach-Object { Write-Output $_ }

    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
