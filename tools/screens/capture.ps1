# Screenshots of the Windows desktop for the acceptance report (CI artifacts): -Count shots, -Every seconds
# apart, as <Dir>/<Prefix>NNN.png. Never fails the step: a runner without a desktop just gets no pictures.
param(
  [Parameter(Mandatory = $true)][string]$Dir,
  [string]$Prefix = "",
  [int]$Count = 1,
  [int]$Every = 5
)
try {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  New-Item -ItemType Directory -Force $Dir | Out-Null
  for ($i = 0; $i -lt $Count; $i++) {
    $area = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object System.Drawing.Bitmap $area.Width, $area.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($area.Left, $area.Top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $Dir ("{0}{1:D3}.png" -f $Prefix, $i)), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose()
    $bitmap.Dispose()
    if ($i -lt $Count - 1) { Start-Sleep -Seconds $Every }
  }
} catch {
  Write-Output "capture: $($_.Exception.Message)"
}
