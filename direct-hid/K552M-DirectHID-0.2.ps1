$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$logPath = Join-Path $PSScriptRoot "K552M-DirectHID-0.2.log"
("=== K552-M Direct HID Lab 0.2.1 ===`r`n" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) |
    Set-Content -LiteralPath $logPath -Encoding UTF8

function Log([string]$s) {
    ("[" + (Get-Date -Format "HH:mm:ss.fff") + "] " + $s) |
        Add-Content -LiteralPath $logPath -Encoding UTF8
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $source = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class K552Direct02
{
    const uint DIGCF_PRESENT = 0x00000002;
    const uint DIGCF_DEVICEINTERFACE = 0x00000010;
    const uint GENERIC_READ  = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ  = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint OPEN_EXISTING = 3;

    static SafeFileHandle handle;
    static readonly object ioLock = new object();

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [DllImport("hid.dll")]
    static extern void HidD_GetHidGuid(out Guid HidGuid);

    [DllImport("hid.dll", SetLastError=true)]
    static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES attributes);

    [DllImport("setupapi.dll", SetLastError=true)]
    static extern IntPtr SetupDiGetClassDevs(
        ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiEnumDeviceInterfaces(
        IntPtr DeviceInfoSet, IntPtr DeviceInfoData, ref Guid InterfaceClassGuid,
        uint MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(
        IntPtr DeviceInfoSet, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData,
        IntPtr DeviceInterfaceDetailData, uint DeviceInterfaceDetailDataSize,
        out uint RequiredSize, IntPtr DeviceInfoData);

    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(
        string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition,
        uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(
        SafeFileHandle hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite,
        out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    public static bool Connected {
        get { return handle != null && !handle.IsInvalid && !handle.IsClosed; }
    }

    static string FindTargetPath()
    {
        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);

        IntPtr set = SetupDiGetClassDevs(
            ref hidGuid, IntPtr.Zero, IntPtr.Zero,
            DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);

        if (set == new IntPtr(-1))
            throw new Exception("SetupDiGetClassDevs falhou: " + Marshal.GetLastWin32Error());

        try {
            for (uint index = 0; ; index++) {
                SP_DEVICE_INTERFACE_DATA ifd = new SP_DEVICE_INTERFACE_DATA();
                ifd.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));

                if (!SetupDiEnumDeviceInterfaces(
                    set, IntPtr.Zero, ref hidGuid, index, ref ifd)) {

                    int err = Marshal.GetLastWin32Error();
                    if (err == 259) break;
                    continue;
                }

                uint needed = 0;
                SetupDiGetDeviceInterfaceDetail(
                    set, ref ifd, IntPtr.Zero, 0, out needed, IntPtr.Zero);

                IntPtr detail = Marshal.AllocHGlobal((int)needed);
                try {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);

                    if (!SetupDiGetDeviceInterfaceDetail(
                        set, ref ifd, detail, needed, out needed, IntPtr.Zero))
                        continue;

                    // Unicode DevicePath begins at offset 4.
                    string path = Marshal.PtrToStringUni(IntPtr.Add(detail, 4));
                    if (String.IsNullOrEmpty(path)) continue;

                    using (SafeFileHandle probe = CreateFile(
                        path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {

                        if (probe.IsInvalid) continue;

                        HIDD_ATTRIBUTES a = new HIDD_ATTRIBUTES();
                        a.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));

                        if (HidD_GetAttributes(probe, ref a) &&
                            a.VendorID == 0x2E3C &&
                            a.ProductID == 0xC365 &&
                            path.ToLowerInvariant().Contains("&mi_02")) {
                            return path;
                        }
                    }
                }
                finally {
                    Marshal.FreeHGlobal(detail);
                }
            }
        }
        finally {
            SetupDiDestroyDeviceInfoList(set);
        }

        throw new Exception("K552-M MI_02 (VID 2E3C / PID C365) nao encontrada.");
    }

    public static string Connect()
    {
        lock (ioLock) {
            Disconnect();

            string path = FindTargetPath();

            handle = CreateFile(
                path,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                0,
                IntPtr.Zero);

            if (handle == null || handle.IsInvalid)
                throw new Exception(
                    "CreateFile MI_02 falhou. Win32=" + Marshal.GetLastWin32Error());

            return path;
        }
    }

    public static void Disconnect()
    {
        lock (ioLock) {
            try {
                if (handle != null && !handle.IsInvalid && !handle.IsClosed)
                    handle.Dispose();
            } catch {}
            handle = null;
        }
    }

    static void RawWrite(byte[] report)
    {
        if (report == null || report.Length != 64)
            throw new ArgumentException("Report precisa ter exatamente 64 bytes.");

        if (!Connected)
            throw new Exception("MI_02 nao esta conectada.");

        uint written;
        if (!WriteFile(handle, report, 64, out written, IntPtr.Zero))
            throw new Exception(
                "WriteFile falhou. Win32=" + Marshal.GetLastWin32Error());

        if (written != 64)
            throw new Exception("WriteFile retornou apenas " + written + " bytes.");
    }

    public static void SendHeartbeat()
    {
        lock (ioLock) {
            byte[] p = new byte[64];
            // Capturado no writer final: 01 01 00 00 00 01 00...
            p[0] = 0x01;
            p[1] = 0x01;
            p[2] = 0x00;
            p[3] = 0x00;
            p[4] = 0x00;
            p[5] = 0x01;
            p[6] = 0x00;
            RawWrite(p);
        }
    }

    static void SendLedPacket(int bank, int chunk, int payloadBytes, byte[] rgb, int startPixel)
    {
        byte[] p = new byte[64];

        // IMPORTANTE:
        // O capture 2 confirmou que o SDK transforma 01 0E em 01 0F
        // antes do writer HID final.
        p[0] = 0x01;
        p[1] = 0x0F;
        p[2] = (byte)bank;
        p[3] = 0x00;
        p[4] = (byte)chunk;
        p[5] = (byte)payloadBytes;

        int pixels = payloadBytes / 3;
        for (int i = 0; i < pixels; i++) {
            int src = (startPixel + i) * 3;
            int dst = 6 + i * 3;
            p[dst]     = rgb[src];
            p[dst + 1] = rgb[src + 1];
            p[dst + 2] = rgb[src + 2];
        }

        RawWrite(p);
    }

    public static void SendFrame(byte[] rgb)
    {
        if (rgb == null || rgb.Length != 165 * 3)
            throw new ArgumentException("Frame precisa conter 165 RGB triples.");

        lock (ioLock) {
            int pixel = 0;

            // Bank 0: 132 slots
            for (int chunk = 0; chunk < 7; chunk++) {
                SendLedPacket(0, chunk, 54, rgb, pixel);
                pixel += 18;
            }

            SendLedPacket(0, 7, 18, rgb, pixel);
            pixel += 6;

            // Bank 1: 33 slots
            SendLedPacket(1, 0, 54, rgb, pixel);
            pixel += 18;

            SendLedPacket(1, 1, 45, rgb, pixel);
        }
    }

    public static void SendSolid(int r, int g, int b)
    {
        byte[] rgb = new byte[165 * 3];
        for (int i = 0; i < 165; i++) {
            rgb[i * 3]     = (byte)r;
            rgb[i * 3 + 1] = (byte)g;
            rgb[i * 3 + 2] = (byte)b;
        }
        SendFrame(rgb);
    }

    static byte Clip(double v)
    {
        int n = (int)Math.Round(v);
        if (n < 0) n = 0;
        if (n > 255) n = 255;
        return (byte)n;
    }

    static void ColorAt(int[] colors, double t, out byte r, out byte g, out byte b)
    {
        if (colors == null || colors.Length < 2) {
            r = g = b = 0;
            return;
        }

        t -= Math.Floor(t);
        double x = t * colors.Length;
        int i0 = ((int)Math.Floor(x)) % colors.Length;
        int i1 = (i0 + 1) % colors.Length;
        double f = x - Math.Floor(x);

        int c0 = colors[i0];
        int c1 = colors[i1];

        double r0 = (c0 >> 16) & 255;
        double g0 = (c0 >> 8) & 255;
        double b0 = c0 & 255;

        double r1 = (c1 >> 16) & 255;
        double g1 = (c1 >> 8) & 255;
        double b1 = c1 & 255;

        r = Clip(r0 + (r1 - r0) * f);
        g = Clip(g0 + (g1 - g0) * f);
        b = Clip(b0 + (b1 - b0) * f);
    }

    public static void SendGradient(int[] colors, double phase, double brightness)
    {
        if (brightness < 0.0) brightness = 0.0;
        if (brightness > 1.5) brightness = 1.5;

        byte[] rgb = new byte[165 * 3];

        for (int i = 0; i < 165; i++) {
            double t = (i / 164.0 + phase) % 1.0;
            byte r, g, b;
            ColorAt(colors, t, out r, out g, out b);

            rgb[i * 3]     = Clip(r * brightness);
            rgb[i * 3 + 1] = Clip(g * brightness);
            rgb[i * 3 + 2] = Clip(b * brightness);
        }

        SendFrame(rgb);
    }

    static byte[] ParseHex64(string s)
    {
        string[] parts = s.Split(new char[]{' '}, StringSplitOptions.RemoveEmptyEntries);

        if (parts.Length > 64)
            throw new Exception("Sample possui mais de 64 bytes: " + parts.Length);

        // Alguns samples copiados para o prototipo omitiram apenas zeros de padding
        // no final. Reports HID da MI_02 sao sempre 64 bytes, entao completamos
        // automaticamente o restante com 00.
        byte[] b = new byte[64];
        for (int i = 0; i < parts.Length; i++)
            b[i] = Convert.ToByte(parts[i], 16);

        return b;
    }

    public static void ReplayCapturedSample()
    {
        // Um frame real capturado DEPOIS da transformacao do SDK.
        // Samples #2..#11 do Transport Capture 2.
        string[] packets = new string[] {
            "01 0F 00 00 00 36 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "01 0F 00 00 01 36 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "01 0F 00 00 02 36 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "01 0F 00 00 03 36 00 B3 B3 00 B3 B3 00 5A B3 00 5A B3 00 00 B3 00 00 B3 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 B3 00 00 00 00 00 B3 B3 00 B3 B3 00 5A B3 00 5A B3 00 00 00 00 00",
            "01 0F 00 00 04 36 00 B3 00 00 B3 00 00 B3 5A 00 B3 5A 00 FE FE 00 FE FE 00 7F FE 00 7F FE 00 00 FE 00 00 FE 5A 00 B3 B3 00 B3 00 00 00 00 00 00 00 00 00 00 00 00 FE 00 00 B3 5A 00 00 00 00 00",
            "01 0F 00 00 05 36 FE FE 00 FE FE 00 7F FE 00 7F FE 00 00 FE 00 00 FE 00 00 FE 7F 00 FE 7F 00 FE FE 00 FE FE 00 7F FE 00 7F FE 00 00 FE 00 00 FE 7F 00 FE FE 00 FE 00 00 00 00 00 00 00 00 00 00",
            "01 0F 00 00 06 36 00 00 00 00 00 00 FE 00 00 FE 7F 00 FE FE 00 FE FE 00 7F FE 00 7F FE 00 00 FE 00 00 FE 00 00 FE 7F 00 FE 7F 00 FE FE 00 FE FE 00 7F FE 00 7F FE 00 00 FE 00 00 FE 00 00 00 00",
            "01 0F 00 00 07 12 7F 00 FE FE 00 FE 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "01 0F 01 00 00 36 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
            "01 0F 01 00 01 2D 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
        };

        lock (ioLock) {
            foreach (string s in packets)
                RawWrite(ParseHex64(s));
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
    Log "Engine compilado."

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "K552-M Direct HID Lab 0.2.1"
    $form.Size = [System.Drawing.Size]::new(720, 610)
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $false
    $form.FormBorderStyle = "FixedDialog"

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "Direct HID Lab 0.2.1 - replay corrigido"
    $title.Font = [System.Drawing.Font]::new("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $title.Location = [System.Drawing.Point]::new(18, 15)
    $title.Size = [System.Drawing.Size]::new(660, 30)
    $form.Controls.Add($title)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = "Feche completamente o app da Redragon. Agora o Lab usa 01 0F, exatamente como apareceu no writer HID final, e envia o heartbeat 01 01 observado na captura."
    $info.Location = [System.Drawing.Point]::new(20, 52)
    $info.Size = [System.Drawing.Size]::new(660, 55)
    $form.Controls.Add($info)

    $connect = New-Object System.Windows.Forms.Button
    $connect.Text = "CONECTAR MI_02"
    $connect.Location = [System.Drawing.Point]::new(20, 115)
    $connect.Size = [System.Drawing.Size]::new(180, 42)
    $form.Controls.Add($connect)

    $disconnect = New-Object System.Windows.Forms.Button
    $disconnect.Text = "DESCONECTAR"
    $disconnect.Location = [System.Drawing.Point]::new(210, 115)
    $disconnect.Size = [System.Drawing.Size]::new(150, 42)
    $form.Controls.Add($disconnect)

    $hb = New-Object System.Windows.Forms.CheckBox
    $hb.Text = "Heartbeat 01 01 a cada 1 s"
    $hb.Checked = $true
    $hb.Location = [System.Drawing.Point]::new(375, 125)
    $hb.Size = [System.Drawing.Size]::new(220, 25)
    $form.Controls.Add($hb)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = "Status: desconectado"
    $status.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $status.Location = [System.Drawing.Point]::new(20, 168)
    $status.Size = [System.Drawing.Size]::new(660, 28)
    $form.Controls.Add($status)

    $sample = New-Object System.Windows.Forms.Button
    $sample.Text = "REPLAY FRAME REAL CAPTURADO"
    $sample.Location = [System.Drawing.Point]::new(20, 205)
    $sample.Size = [System.Drawing.Size]::new(310, 42)
    $form.Controls.Add($sample)

    $sampleHelp = New-Object System.Windows.Forms.Label
    $sampleHelp.Text = "Primeiro teste recomendado: reproduz literalmente um frame que o software oficial enviou."
    $sampleHelp.Location = [System.Drawing.Point]::new(345, 211)
    $sampleHelp.Size = [System.Drawing.Size]::new(330, 40)
    $form.Controls.Add($sampleHelp)

    $colors = @(
        @("Vermelho",255,0,0),
        @("Verde",0,255,0),
        @("Azul",0,0,255),
        @("Magenta",255,0,255),
        @("Ciano",0,255,255),
        @("Branco",255,255,255),
        @("Apagar",0,0,0)
    )

    $x = 20
    $y = 270
    foreach ($c in $colors) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = [string]$c[0]
        $b.Tag = "$($c[1]),$($c[2]),$($c[3])"
        $b.Location = [System.Drawing.Point]::new($x,$y)
        $b.Size = [System.Drawing.Size]::new(150,40)
        $form.Controls.Add($b)

        $b.Add_Click({
            try {
                if ($hb.Checked) { [K552Direct02]::SendHeartbeat() }
                $p = $this.Tag.Split(',')
                [K552Direct02]::SendSolid([int]$p[0],[int]$p[1],[int]$p[2])
                $status.Text = "Status: frame " + $this.Text + " enviado"
                Log ("Solid enviado: " + $this.Text)
            } catch {
                Log ("Solid ERRO: " + $_.Exception.ToString())
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Direct HID") | Out-Null
            }
        })

        $x += 165
        if ($x -gt 550) {
            $x = 20
            $y += 50
        }
    }

    $palLabel = New-Object System.Windows.Forms.Label
    $palLabel.Text = "Paleta do gradiente:"
    $palLabel.Location = [System.Drawing.Point]::new(20, 380)
    $palLabel.Size = [System.Drawing.Size]::new(145,25)
    $form.Controls.Add($palLabel)

    $palText = New-Object System.Windows.Forms.TextBox
    $palText.Text = "FF2FA0,A54DFF,4169FF,00E5FF"
    $palText.Location = [System.Drawing.Point]::new(165, 377)
    $palText.Size = [System.Drawing.Size]::new(510,25)
    $form.Controls.Add($palText)

    $speedLabel = New-Object System.Windows.Forms.Label
    $speedLabel.Text = "Velocidade: 60%"
    $speedLabel.Location = [System.Drawing.Point]::new(20,425)
    $speedLabel.Size = [System.Drawing.Size]::new(135,25)
    $form.Controls.Add($speedLabel)

    $speed = New-Object System.Windows.Forms.TrackBar
    $speed.Minimum = 5
    $speed.Maximum = 200
    $speed.Value = 60
    $speed.TickFrequency = 25
    $speed.Location = [System.Drawing.Point]::new(160,415)
    $speed.Size = [System.Drawing.Size]::new(300,45)
    $form.Controls.Add($speed)

    $animate = New-Object System.Windows.Forms.Button
    $animate.Text = "INICIAR GRADIENTE"
    $animate.Location = [System.Drawing.Point]::new(475,418)
    $animate.Size = [System.Drawing.Size]::new(200,42)
    $form.Controls.Add($animate)

    $diag = New-Object System.Windows.Forms.Label
    $diag.Text = "Se o Replay Frame Real funcionar, o transporte direto esta confirmado. Se o replay nao funcionar, envie o log e partimos para capturar a abertura/handshake da MI_02."
    $diag.Location = [System.Drawing.Point]::new(20,485)
    $diag.Size = [System.Drawing.Size]::new(655,55)
    $form.Controls.Add($diag)

    $heartbeatTimer = New-Object System.Windows.Forms.Timer
    $heartbeatTimer.Interval = 1000
    $heartbeatTimer.Add_Tick({
        if ($hb.Checked -and [K552Direct02]::Connected) {
            try {
                [K552Direct02]::SendHeartbeat()
            } catch {
                Log ("Heartbeat ERRO: " + $_.Exception.Message)
            }
        }
    })

    $gradientTimer = New-Object System.Windows.Forms.Timer
    $gradientTimer.Interval = 33
    $phase = 0.0
    $animating = $false

    function Parse-Palette {
        $list = New-Object System.Collections.Generic.List[int]
        foreach ($s in $palText.Text.Split(',')) {
            $t = $s.Trim().TrimStart('#')
            if ($t -match '^[0-9A-Fa-f]{6}$') {
                $list.Add([Convert]::ToInt32($t,16))
            }
        }
        if ($list.Count -lt 2) {
            throw "Use pelo menos 2 cores HEX separadas por virgula."
        }
        return $list.ToArray()
    }

    $gradientTimer.Add_Tick({
        try {
            $phase += ($speed.Value / 100.0) * 0.012
            $p = Parse-Palette
            [K552Direct02]::SendGradient($p, $phase, 1.0)
        } catch {
            $gradientTimer.Stop()
            $animating = $false
            $animate.Text = "INICIAR GRADIENTE"
            Log ("Gradient ERRO: " + $_.Exception.ToString())
            $status.Text = "Status: erro no gradiente"
        }
    })

    $speed.Add_ValueChanged({
        $speedLabel.Text = "Velocidade: " + $speed.Value + "%"
    })

    $connect.Add_Click({
        try {
            $p = [K552Direct02]::Connect()
            Log ("Conectado: " + $p)
            $status.Text = "Status: conectado em MI_02"
            [K552Direct02]::SendHeartbeat()
            Log "Heartbeat inicial enviado."
            $heartbeatTimer.Start()
        } catch {
            Log ("Connect ERRO: " + $_.Exception.ToString())
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Direct HID") | Out-Null
        }
    })

    $disconnect.Add_Click({
        try {
            $gradientTimer.Stop()
            $heartbeatTimer.Stop()
            $animating = $false
            $animate.Text = "INICIAR GRADIENTE"
            [K552Direct02]::Disconnect()
            $status.Text = "Status: desconectado"
            Log "Desconectado."
        } catch {}
    })

    $sample.Add_Click({
        try {
            if ($hb.Checked) { [K552Direct02]::SendHeartbeat() }
            [K552Direct02]::ReplayCapturedSample()
            $status.Text = "Status: frame real capturado enviado"
            Log "Replay de frame real enviado com sucesso."
        } catch {
            Log ("Replay ERRO: " + $_.Exception.ToString())
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Direct HID") | Out-Null
        }
    })

    $animate.Add_Click({
        if (-not $animating) {
            try {
                $null = Parse-Palette
                if ($hb.Checked) { [K552Direct02]::SendHeartbeat() }
                $animating = $true
                $animate.Text = "PARAR GRADIENTE"
                $gradientTimer.Start()
                Log "Gradiente iniciado."
            } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Direct HID") | Out-Null
            }
        } else {
            $gradientTimer.Stop()
            $animating = $false
            $animate.Text = "INICIAR GRADIENTE"
            Log "Gradiente parado."
        }
    })

    $form.Add_FormClosing({
        try {
            $gradientTimer.Stop()
            $heartbeatTimer.Stop()
            [K552Direct02]::Disconnect()
        } catch {}
    })

    [void]$form.ShowDialog()
}
catch {
    Log ("FATAL: " + $_.Exception.ToString())
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Erro: " + $_.Exception.Message + "`r`n`r`nEnvie K552M-DirectHID-0.2.log",
            "K552-M Direct HID Lab 0.2.1") | Out-Null
    } catch {}
    exit 1
}
