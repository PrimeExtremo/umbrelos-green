$ErrorActionPreference = 'Stop'
$ExpectedUniqueId = 'USBSTOR\DISK&VEN_GENERIC&PROD_MASSSTORAGECLASS&REV_1539\000000001539&1:PrimePC'
$ExpectedSize = 63281561600L
$ImagePath = 'C:\Users\jener\Documents\Codex\2026-10-22\i-x20\outputs\green-umbrel-installer.img'
$ExpectedHash = '5020bc449b889f9f9041ca14d5a355159db5ff18bf65e790504d10f174010f54'
$ResultPath = 'C:\Users\jener\Documents\Codex\2026-10-22\i-x20\work\sd-write-umbrel-installer-result.json'
$LogPath = 'C:\Users\jener\Documents\Codex\2026-10-22\i-x20\work\sd-write-umbrel-installer.log'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RawDiskIO {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WriteFile(SafeFileHandle handle, byte[] buffer, int count, out int written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadFile(SafeFileHandle handle, byte[] buffer, int count, out int read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool FlushFileBuffers(SafeFileHandle handle);
}
'@

Start-Transcript -Path $LogPath -Force
try {
    $image = Get-Item -LiteralPath $ImagePath
    $sourceHash = (Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $ExpectedHash) { throw "Image checksum mismatch: $sourceHash" }
    $disk = @(Get-Disk | Where-Object UniqueId -eq $ExpectedUniqueId)
    if ($disk.Count -ne 1) { throw "Expected one matching card, found $($disk.Count)" }
    $disk = $disk[0]
    if ($disk.Number -ne 5 -or $disk.BusType -ne 'USB' -or $disk.Size -ne $ExpectedSize -or $disk.IsBoot -or $disk.IsSystem -or $disk.IsReadOnly) { throw 'SD safety preflight failed' }
    if ($image.Length -ge $disk.Size) { throw 'Image does not fit' }
    # Remove any stale or partial partition metadata left by earlier imaging
    # attempts after all identity and safety checks have passed.
    if (@($disk | Get-Partition -ErrorAction SilentlyContinue).Count -ne 0) {
        Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
        Start-Sleep -Seconds 5
        Update-HostStorageCache
    }

    $device = "\\.\PhysicalDrive$($disk.Number)"
    $handle = [RawDiskIO]::CreateFile($device, 3221225472, 3, [IntPtr]::Zero, 3, 2147483648, [IntPtr]::Zero)
    if ($handle.IsInvalid) { throw "CreateFile failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    $source = [IO.File]::OpenRead($ImagePath)
    try {
        $buffer = [byte[]]::new(4194304)
        $total = 0L
        $next = 536870912L
        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $written = 0
            if (-not [RawDiskIO]::WriteFile($handle, $buffer, $count, [ref]$written, [IntPtr]::Zero)) {
                throw "Native WriteFile failed at byte $total`: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            if ($written -ne $count) { throw "Short write at byte $total`: $written of $count" }
            $total += $written
            if ($total -ge $next) { Write-Host ("Written {0:N1} GiB" -f ($total / 1GB)); $next += 536870912L }
        }
        if ($total -ne $image.Length) { throw "Write length mismatch: $total" }
        if (-not [RawDiskIO]::FlushFileBuffers($handle)) { throw "Flush failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    }
    finally {
        $source.Dispose()
        $handle.Dispose()
    }

    $handle = [RawDiskIO]::CreateFile($device, 2147483648, 3, [IntPtr]::Zero, 3, 134217728, [IntPtr]::Zero)
    if ($handle.IsInvalid) { throw "Readback CreateFile failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $buffer = [byte[]]::new(4194304)
        $remaining = $image.Length
        while ($remaining -gt 0) {
            $wanted = [int][Math]::Min([long]$buffer.Length, [long]$remaining)
            $read = 0
            if (-not [RawDiskIO]::ReadFile($handle, $buffer, $wanted, [ref]$read, [IntPtr]::Zero)) { throw "Readback failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
            if ($read -le 0) { throw "Short read with $remaining bytes remaining" }
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $remaining -= $read
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        $readbackHash = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $handle.Dispose()
    }
    if ($readbackHash -ne $ExpectedHash) { throw "Readback checksum mismatch: $readbackHash" }
    Update-HostStorageCache
    [pscustomobject]@{success=$true; disk_number=$disk.Number; unique_id=$disk.UniqueId; disk_size=$disk.Size; image_size=$image.Length; sha256=$readbackHash; completed_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
    Write-Host 'Native write and full readback verification succeeded'
}
catch {
    [pscustomobject]@{success=$false; error=$_.Exception.Message; completed_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
    throw
}
finally { Stop-Transcript }
