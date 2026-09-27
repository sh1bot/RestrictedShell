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

# Windows PowerShell 5.1 has no Core Audio cmdlets. This C# block is only the
# interop boundary: enumerate render endpoints and set one endpoint's volume.
# Endpoint-selection policy remains ordinary PowerShell below.
if (-not ('RestrictedShell.AudioEndpoints' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace RestrictedShell
{
    public sealed class AudioEndpoint
    {
        public string Id;
        public string Name;
        public uint FormFactor;
        public bool Active;
        public bool Private;
        public bool DefaultConsole;
        public bool DefaultMultimedia;
        public bool DefaultCommunications;
    }

    enum EDataFlow { Render = 0 }
    enum ERole { Console = 0, Multimedia = 1, Communications = 2 }

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

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        void EnumAudioEndpoints(EDataFlow flow, uint stateMask, out IMMDeviceCollection devices);
        void GetDefaultAudioEndpoint(EDataFlow flow, ERole role, out IMMDevice device);
        void GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        void GetCount(out uint count);
        void Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        void Activate(ref Guid iid, uint clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object result);
        void OpenPropertyStore(uint access, out IPropertyStore properties);
        void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetState(out uint state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PROPERTYKEY key);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        void RegisterControlChangeNotify(IntPtr notify);
        void UnregisterControlChangeNotify(IntPtr notify);
        void GetChannelCount(out uint channelCount);
        void SetMasterVolumeLevel(float levelDb, IntPtr eventContext);
        void SetMasterVolumeLevelScalar(float level, IntPtr eventContext);
    }

    public static class AudioEndpoints
    {
        const uint Active = 0x1;
        const uint Unplugged = 0x8;
        const uint Read = 0;
        const uint ClsCtxAll = 23;
        const ushort VT_UI4 = 19;
        const ushort VT_LPWSTR = 31;

        static readonly PROPERTYKEY FriendlyName =
            new PROPERTYKEY("A45C254E-DF1C-4EFD-8020-67D146A850E0", 14);
        static readonly PROPERTYKEY FormFactor =
            new PROPERTYKEY("1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E", 0);
        static readonly Guid EndpointVolumeIid =
            new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PROPVARIANT value);

        static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value))
                Marshal.ReleaseComObject(value);
        }

        static string DefaultId(IMMDeviceEnumerator e, ERole role)
        {
            IMMDevice device = null;
            try
            {
                e.GetDefaultAudioEndpoint(EDataFlow.Render, role, out device);
                string id;
                device.GetId(out id);
                return id;
            }
            catch (COMException)
            {
                return null;
            }
            finally
            {
                Release(device);
            }
        }

        static string StringProperty(IPropertyStore store, PROPERTYKEY key)
        {
            PROPVARIANT value;
            store.GetValue(ref key, out value);
            try
            {
                return value.vt == VT_LPWSTR && value.pointerValue != IntPtr.Zero
                    ? Marshal.PtrToStringUni(value.pointerValue)
                    : null;
            }
            finally
            {
                PropVariantClear(ref value);
            }
        }

        static uint UIntProperty(IPropertyStore store, PROPERTYKEY key, uint fallback)
        {
            PROPVARIANT value;
            store.GetValue(ref key, out value);
            try
            {
                return value.vt == VT_UI4 ? value.uintValue : fallback;
            }
            finally
            {
                PropVariantClear(ref value);
            }
        }

        static bool Same(string a, string b)
        {
            return a != null && b != null &&
                String.Equals(a, b, StringComparison.OrdinalIgnoreCase);
        }

        public static AudioEndpoint[] Enumerate()
        {
            IMMDeviceEnumerator e = null;
            IMMDeviceCollection devices = null;
            List<AudioEndpoint> result = new List<AudioEndpoint>();
            try
            {
                e = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                string console = DefaultId(e, ERole.Console);
                string multimedia = DefaultId(e, ERole.Multimedia);
                string communications = DefaultId(e, ERole.Communications);

                e.EnumAudioEndpoints(EDataFlow.Render, Active | Unplugged, out devices);
                uint count;
                devices.GetCount(out count);

                for (uint i = 0; i < count; i++)
                {
                    IMMDevice device = null;
                    IPropertyStore properties = null;
                    try
                    {
                        devices.Item(i, out device);
                        string id;
                        uint state;
                        device.GetId(out id);
                        device.GetState(out state);
                        device.OpenPropertyStore(Read, out properties);

                        string name = StringProperty(properties, FriendlyName);
                        uint form = UIntProperty(properties, FormFactor, 10);
                        result.Add(new AudioEndpoint {
                            Id = id,
                            Name = String.IsNullOrEmpty(name) ? id : name,
                            FormFactor = form,
                            Active = (state & Active) != 0,
                            Private = form == 3 || form == 5 || form == 6,
                            DefaultConsole = Same(id, console),
                            DefaultMultimedia = Same(id, multimedia),
                            DefaultCommunications = Same(id, communications)
                        });
                    }
                    finally
                    {
                        Release(properties);
                        Release(device);
                    }
                }
                return result.ToArray();
            }
            finally
            {
                Release(devices);
                Release(e);
            }
        }

        public static void SetVolume(string id, int percent)
        {
            if (percent < 0 || percent > 100)
                throw new ArgumentOutOfRangeException("percent");

            IMMDeviceEnumerator e = null;
            IMMDevice device = null;
            object volume = null;
            try
            {
                e = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                e.GetDevice(id, out device);
                Guid iid = EndpointVolumeIid;
                device.Activate(ref iid, ClsCtxAll, IntPtr.Zero, out volume);
                ((IAudioEndpointVolume)volume).SetMasterVolumeLevelScalar(
                    percent / 100.0f, IntPtr.Zero);
            }
            finally
            {
                Release(volume);
                Release(device);
                Release(e);
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
    param([string]$Path, [string]$Name)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "INI file not found: $Path"
    }

    $values = @{}
    $inside = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = $line.Trim()
        if ($text -match '^\[(.+)\]$') {
            $inside = $matches[1] -eq $Name
        }
        elseif ($inside -and $text -match '^([^;#][^=]*)=(.*)$') {
            $values[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $values
}

function Get-VolumeSetting {
    param($Values, [string]$Name)
    $value = 0
    if (-not $Values.ContainsKey($Name) -or
        -not [int]::TryParse($Values[$Name], [ref]$value) -or
        $value -lt 0 -or $value -gt 100) {
        throw "[$Section] $Name must be an integer from 0 to 100."
    }
    return $value
}

$formFactorNames = @{
    0='RemoteNetworkDevice'; 1='Speakers'; 2='LineLevel'; 3='Headphones'
    5='Headset'; 6='Handset'; 7='UnknownDigitalPassthrough'; 8='SPDIF'
    9='DigitalAudioDisplayDevice'; 10='UnknownFormFactor'
}
$publicFormPreference = @(1,2,9,8,7,10)
$privateFormPreference = @(3,5,6)

function Get-FormPreference {
    param($Endpoint, [bool]$Private)
    $order = if ($Private) { $privateFormPreference } else { $publicFormPreference }
    $index = [Array]::IndexOf($order, [int]$Endpoint.FormFactor)
    if ($index -lt 0) { return 0 }
    return $order.Count - $index
}

function Select-BestEndpoint {
    param($Endpoints, [bool]$Private)

    return $Endpoints |
        Sort-Object `
            @{Expression={$_.DefaultMultimedia};Descending=$true}, `
            @{Expression={$_.DefaultConsole};Descending=$true}, `
            @{Expression={$_.DefaultCommunications};Descending=$true}, `
            @{Expression={$_.Active};Descending=$true}, `
            @{Expression={Get-FormPreference $_ $Private};Descending=$true} |
        Select-Object -First 1
}

function Describe-Endpoint {
    param($Endpoint)
    $form = $formFactorNames[[int]$Endpoint.FormFactor]
    if (-not $form) { $form = "FormFactor$($Endpoint.FormFactor)" }
    return "$($Endpoint.Name) ($form)"
}

try {
    $settings = Read-IniSection $IniPath $Section
    $publicVolume = Get-VolumeSetting $settings 'PublicVolume'
    $privateVolume = Get-VolumeSetting $settings 'PrivateVolume'
    $endpoints = @([RestrictedShell.AudioEndpoints]::Enumerate())
    if (-not $endpoints.Count) {
        throw 'No active or unplugged render endpoints were found.'
    }

    $publicCandidates = @($endpoints | Where-Object { -not $_.Private })
    $usedSafetyFallback = -not $publicCandidates.Count
    if ($usedSafetyFallback) { $publicCandidates = $endpoints }

    $public = Select-BestEndpoint $publicCandidates $false
    [RestrictedShell.AudioEndpoints]::SetVolume($public.Id, $publicVolume)
    if ($usedSafetyFallback) {
        Write-Output "No distinct public endpoint was identifiable; treating $(Describe-Endpoint $public) as public for safety."
    }
    Write-Output "Public: $(Describe-Endpoint $public) -> $publicVolume%"

    $private = Select-BestEndpoint @($endpoints | Where-Object {
        $_.Private -and $_.Id -ne $public.Id
    }) $true

    if ($private) {
        try {
            [RestrictedShell.AudioEndpoints]::SetVolume($private.Id, $privateVolume)
            Write-Output "Private: $(Describe-Endpoint $private) -> $privateVolume%"
        }
        catch {
            Write-Output "Warning: could not preset private endpoint $(Describe-Endpoint $private): $($_.Exception.Message)"
        }
    }
    else {
        Write-Output 'No distinct private headphone/headset endpoint was found.'
    }

    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
