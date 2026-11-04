$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$logPath = Join-Path $PSScriptRoot "K552M-MusicPalette.log"
("=== K552-M Studio 0.4 ===`r`n" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) |
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
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Threading;
using System.Runtime.InteropServices;

public static class K552PaletteHook
{
    const uint TH32CS_SNAPMODULE = 0x00000008;
    const uint TH32CS_SNAPMODULE32 = 0x00000010;

    const uint PROCESS_QUERY_INFORMATION = 0x0400;
    const uint PROCESS_VM_OPERATION = 0x0008;
    const uint PROCESS_VM_READ = 0x0010;
    const uint PROCESS_VM_WRITE = 0x0020;

    const uint THREAD_GET_CONTEXT = 0x0008;
    const uint THREAD_SET_CONTEXT = 0x0010;
    const uint THREAD_QUERY_INFORMATION = 0x0040;

    const uint CONTEXT_i386 = 0x00010000;
    const uint CONTEXT_CONTROL = CONTEXT_i386 | 0x00000001;
    const uint CONTEXT_INTEGER = CONTEXT_i386 | 0x00000002;
    const uint CONTEXT_SEGMENTS = CONTEXT_i386 | 0x00000004;
    const uint CONTEXT_FULL = CONTEXT_CONTROL | CONTEXT_INTEGER | CONTEXT_SEGMENTS;

    const uint EXCEPTION_DEBUG_EVENT = 1;
    const uint EXIT_PROCESS_DEBUG_EVENT = 5;
    const uint EXCEPTION_BREAKPOINT = 0x80000003;
    const uint EXCEPTION_SINGLE_STEP = 0x80000004;

    const uint DBG_CONTINUE = 0x00010002;
    const uint DBG_EXCEPTION_NOT_HANDLED = 0x80010001;

    // RVA confirmed against the witmodSdk.dll used in the successful capture.
    const int HIDWRITE_RVA = 0x00008520;

    static readonly object cfgLock = new object();
    static int[] palette = new int[] {
        0xFF2FA0, 0xA54DFF, 0x4169FF, 0x00E5FF
    };
    static int mapMode = 0; // 0=hue, 1=posicao, 2=onda, 3=ciclo, 4=intensidade, 5=hue+movimento
    static double brightness = 1.0;
    static double effectSpeed = 0.75;
    static double saturation = 1.0;
    static double smoothing = 0.0;
    static double redGain = 1.0;
    static double greenGain = 1.0;
    static double blueGain = 1.0;
    static double gamma = 1.0;

    static Thread worker;
    static volatile bool stopRequested;
    static volatile bool running;
    static byte[] previousRgb = new byte[165 * 3];
    static string status = "Parado";
    static string lastError = "";

    public static bool IsRunning { get { return running; } }
    public static string Status { get { return status; } }
    public static string LastError { get { return lastError; } }

    public static void SetPalette(int[] colors)
    {
        if (colors == null || colors.Length < 2) return;
        lock (cfgLock) {
            palette = (int[])colors.Clone();
        }
    }

    public static void SetMode(int mode)
    {
        if (mode < 0) mode = 0;
        if (mode > 5) mode = 5;
        mapMode = mode;
    }

    public static void SetSpeed(double value)
    {
        if (value < 0.05) value = 0.05;
        if (value > 5.00) value = 5.00;
        effectSpeed = value;
    }

    public static void SetSaturation(double value)
    {
        if (value < 0.0) value = 0.0;
        if (value > 2.0) value = 2.0;
        saturation = value;
    }

    public static void SetSmoothing(double value)
    {
        if (value < 0.0) value = 0.0;
        if (value > 0.95) value = 0.95;
        smoothing = value;
    }

    public static void SetBrightness(double value)
    {
        if (value < 0.10) value = 0.10;
        if (value > 2.00) value = 2.00;
        brightness = value;
    }

    public static void SetCalibration(double r, double g, double b, double gma)
    {
        if (r < 0.25) r = 0.25; if (r > 2.50) r = 2.50;
        if (g < 0.25) g = 0.25; if (g > 2.50) g = 2.50;
        if (b < 0.25) b = 0.25; if (b > 2.50) b = 2.50;
        if (gma < 0.50) gma = 0.50; if (gma > 2.50) gma = 2.50;
        redGain = r;
        greenGain = g;
        blueGain = b;
        gamma = gma;
    }

    public static void Start(int pid)
    {
        if (running) return;
        stopRequested = false;
        lastError = "";
        worker = new Thread(() => Worker(pid));
        worker.IsBackground = true;
        worker.Name = "K552PaletteHook";
        worker.Start();
    }

    public static void Stop()
    {
        stopRequested = true;
        status = "Parando com seguranca...";
        Thread t = worker;
        if (t != null && t.IsAlive)
            t.Join(5000);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MODULEENTRY32 {
        public uint dwSize, th32ModuleID, th32ProcessID, GlblcntUsage, ProccntUsage;
        public IntPtr modBaseAddr;
        public uint modBaseSize;
        public IntPtr hModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string szModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string szExePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FLOATING_SAVE_AREA {
        public uint ControlWord, StatusWord, TagWord, ErrorOffset, ErrorSelector, DataOffset, DataSelector;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=80)] public byte[] RegisterArea;
        public uint Cr0NpxState;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct CONTEXT {
        public uint ContextFlags;
        public uint Dr0, Dr1, Dr2, Dr3, Dr6, Dr7;
        public FLOATING_SAVE_AREA FloatSave;
        public uint SegGs, SegFs, SegEs, SegDs;
        public uint Edi, Esi, Ebx, Edx, Ecx, Eax;
        public uint Ebp, Eip, SegCs, EFlags, Esp, SegSs;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=512)] public byte[] ExtendedRegisters;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct EXCEPTION_RECORD32 {
        public uint ExceptionCode, ExceptionFlags, ExceptionRecord, ExceptionAddress, NumberParameters;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=15)] public uint[] ExceptionInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct EXCEPTION_DEBUG_INFO32 {
        public EXCEPTION_RECORD32 ExceptionRecord;
        public uint dwFirstChance;
    }

    [StructLayout(LayoutKind.Explicit, Size=96)]
    struct DEBUG_EVENT32 {
        [FieldOffset(0)] public uint dwDebugEventCode;
        [FieldOffset(4)] public uint dwProcessId;
        [FieldOffset(8)] public uint dwThreadId;
        [FieldOffset(12)] public EXCEPTION_DEBUG_INFO32 Exception;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool Module32FirstW(IntPtr snapshot, ref MODULEENTRY32 entry);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool Module32NextW(IntPtr snapshot, ref MODULEENTRY32 entry);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenThread(uint access, bool inherit, uint tid);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadProcessMemory(IntPtr hp, IntPtr addr, byte[] buffer, int size, out IntPtr read);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteProcessMemory(IntPtr hp, IntPtr addr, byte[] buffer, int size, out IntPtr written);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool FlushInstructionCache(IntPtr hp, IntPtr addr, UIntPtr size);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DebugActiveProcess(uint pid);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DebugActiveProcessStop(uint pid);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DebugSetProcessKillOnExit(bool killOnExit);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WaitForDebugEvent(ref DEBUG_EVENT32 ev, uint ms);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ContinueDebugEvent(uint pid, uint tid, uint status);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetThreadContext(IntPtr thread, ref CONTEXT context);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetThreadContext(IntPtr thread, ref CONTEXT context);

    static IntPtr FindModule(uint pid, string moduleName)
    {
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
        if (snap == new IntPtr(-1))
            throw new Exception("CreateToolhelp32Snapshot falhou: " + Marshal.GetLastWin32Error());

        try {
            MODULEENTRY32 me = new MODULEENTRY32();
            me.dwSize = (uint)Marshal.SizeOf(typeof(MODULEENTRY32));

            if (!Module32FirstW(snap, ref me))
                throw new Exception("Module32First falhou: " + Marshal.GetLastWin32Error());

            do {
                if (String.Equals(me.szModule, moduleName, StringComparison.OrdinalIgnoreCase))
                    return me.modBaseAddr;
            } while (Module32NextW(snap, ref me));
        }
        finally {
            CloseHandle(snap);
        }
        return IntPtr.Zero;
    }

    static CONTEXT NewContext()
    {
        CONTEXT c = new CONTEXT();
        c.ContextFlags = CONTEXT_FULL;
        c.FloatSave.RegisterArea = new byte[80];
        c.ExtendedRegisters = new byte[512];
        return c;
    }

    static bool WriteByte(IntPtr hp, IntPtr addr, byte value)
    {
        IntPtr n;
        bool ok = WriteProcessMemory(hp, addr, new byte[] { value }, 1, out n);
        FlushInstructionCache(hp, addr, new UIntPtr(1));
        return ok && n.ToInt32() == 1;
    }

    static double Hue01(byte r, byte g, byte b)
    {
        double rr = r / 255.0, gg = g / 255.0, bb = b / 255.0;
        double max = Math.Max(rr, Math.Max(gg, bb));
        double min = Math.Min(rr, Math.Min(gg, bb));
        double d = max - min;
        if (d < 0.00001) return 0.0;

        double h;
        if (max == rr) {
            h = ((gg - bb) / d) % 6.0;
        } else if (max == gg) {
            h = ((bb - rr) / d) + 2.0;
        } else {
            h = ((rr - gg) / d) + 4.0;
        }
        h /= 6.0;
        if (h < 0) h += 1.0;
        return h;
    }

    static void PaletteColor(double t, bool cyclic, out double r, out double g, out double b)
    {
        int[] p;
        lock (cfgLock) { p = (int[])palette.Clone(); }

        if (p.Length < 2) {
            r = g = b = 1.0;
            return;
        }

        if (t < 0) t = 0;
        if (t > 1) t = 1;

        int i0, i1;
        double f;

        if (cyclic) {
            double x = t * p.Length;
            i0 = ((int)Math.Floor(x)) % p.Length;
            i1 = (i0 + 1) % p.Length;
            f = x - Math.Floor(x);
        } else {
            double x = t * (p.Length - 1);
            i0 = (int)Math.Floor(x);
            if (i0 >= p.Length - 1) {
                i0 = p.Length - 2;
                f = 1.0;
            } else {
                f = x - i0;
            }
            i1 = i0 + 1;
        }

        int c0 = p[i0], c1 = p[i1];

        double r0 = ((c0 >> 16) & 255) / 255.0;
        double g0 = ((c0 >> 8) & 255) / 255.0;
        double b0 = (c0 & 255) / 255.0;

        double r1 = ((c1 >> 16) & 255) / 255.0;
        double g1 = ((c1 >> 8) & 255) / 255.0;
        double b1 = (c1 & 255) / 255.0;

        r = r0 + (r1 - r0) * f;
        g = g0 + (g1 - g0) * f;
        b = b0 + (b1 - b0) * f;
    }

    static byte Clip(double v)
    {
        int n = (int)Math.Round(v);
        if (n < 0) n = 0;
        if (n > 255) n = 255;
        return (byte)n;
    }

    static bool RecolorReport(byte[] report)
    {
        // Successful capture showed music frames as:
        // 01 0E <bank> 00 <chunk> <payloadLen> [RGB triples...]
        if (report == null || report.Length < 64) return false;
        if (report[0] != 0x01 || report[1] != 0x0E) return false;

        int len = report[5];
        if (len <= 0 || len > 58 || (len % 3) != 0) return false;

        int mode = mapMode;
        double boost = brightness;

        int bank = report[2];
        int chunk = report[4];
        int pixelsPerFullChunk = 18;

        for (int off = 6; off < 6 + len; off += 3) {
            byte sr = report[off];
            byte sg = report[off + 1];
            byte sb = report[off + 2];

            int max = Math.Max(sr, Math.Max(sg, sb));
            if (max == 0) continue;

            int local = (off - 6) / 3;
            int slot = (bank == 0 ? 0 : 132) + chunk * pixelsPerFullChunk + local;
            double pos = slot / 164.0;
            if (pos < 0) pos = 0;
            if (pos > 1) pos = 1;

            double phase = ((Environment.TickCount & Int32.MaxValue) / 1000.0 * effectSpeed) % 1.0;
            double sourceHue = Hue01(sr, sg, sb);
            double t;
            bool cyclic;

            switch (mode) {
                case 1: // gradient by key/LED position
                    t = pos;
                    cyclic = false;
                    break;
                case 2: // moving wave over keyboard
                    t = (pos + phase) % 1.0;
                    cyclic = true;
                    break;
                case 3: // entire keyboard cycles together, intensity still audio-reactive
                    t = phase;
                    cyclic = true;
                    break;
                case 4: // loudness selects color
                    t = max / 255.0;
                    cyclic = false;
                    break;
                case 5: // original hue remap with continuous palette drift
                    t = (sourceHue + phase) % 1.0;
                    cyclic = true;
                    break;
                default: // original rainbow remapped to selected palette
                    t = sourceHue;
                    cyclic = true;
                    break;
            }

            double pr, pg, pb;
            PaletteColor(t, cyclic, out pr, out pg, out pb);

            double v = (max / 255.0) * boost;

            double invGamma = 1.0 / gamma;
            double cr = Math.Pow(Math.Max(0.0, Math.Min(1.0, pr)), invGamma) * redGain;
            double cg = Math.Pow(Math.Max(0.0, Math.Min(1.0, pg)), invGamma) * greenGain;
            double cb = Math.Pow(Math.Max(0.0, Math.Min(1.0, pb)), invGamma) * blueGain;

            double lum = (cr + cg + cb) / 3.0;
            cr = lum + (cr - lum) * saturation;
            cg = lum + (cg - lum) * saturation;
            cb = lum + (cb - lum) * saturation;

            byte nr = Clip(cr * 255.0 * v);
            byte ng = Clip(cg * 255.0 * v);
            byte nb = Clip(cb * 255.0 * v);

            int localPixel = (bank == 0 ? 0 : 132) + chunk * pixelsPerFullChunk + ((off - 6) / 3);
            if (localPixel >= 0 && localPixel < 165 && smoothing > 0.0) {
                int pi = localPixel * 3;
                nr = Clip(previousRgb[pi]     * smoothing + nr * (1.0 - smoothing));
                ng = Clip(previousRgb[pi + 1] * smoothing + ng * (1.0 - smoothing));
                nb = Clip(previousRgb[pi + 2] * smoothing + nb * (1.0 - smoothing));
                previousRgb[pi] = nr;
                previousRgb[pi + 1] = ng;
                previousRgb[pi + 2] = nb;
            }

            report[off]     = nr;
            report[off + 1] = ng;
            report[off + 2] = nb;
        }

        return true;
    }

    static void Worker(int pid)
    {
        running = true;
        status = "Conectando...";
        lastError = "";

        IntPtr hp = IntPtr.Zero;
        IntPtr target = IntPtr.Zero;
        bool attached = false;
        bool breakpointArmed = false;
        byte original = 0;

        try {
            if (IntPtr.Size != 4)
                throw new Exception("Use o launcher 32-bit incluido.");

            IntPtr baseAddr = FindModule((uint)pid, "witmodSdk.dll");
            if (baseAddr == IntPtr.Zero)
                throw new Exception("witmodSdk.dll nao esta carregada. Reabra o software Redragon.");

            target = new IntPtr(baseAddr.ToInt32() + HIDWRITE_RVA);

            hp = OpenProcess(
                PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE,
                false, (uint)pid);

            if (hp == IntPtr.Zero)
                throw new Exception("OpenProcess falhou: Win32=" + Marshal.GetLastWin32Error());

            byte[] first = new byte[1];
            IntPtr nr;
            if (!ReadProcessMemory(hp, target, first, 1, out nr) || nr.ToInt32() != 1)
                throw new Exception("Nao foi possivel validar HidWriteBuff.");

            original = first[0];
            if (original != 0x55 && original != 0xCC)
                throw new Exception("A witmodSdk.dll nao corresponde a versao analisada (byte=0x" + original.ToString("X2") + ").");

            if (!DebugActiveProcess((uint)pid))
                throw new Exception("DebugActiveProcess falhou: Win32=" + Marshal.GetLastWin32Error());

            attached = true;
            DebugSetProcessKillOnExit(false);

            if (!WriteByte(hp, target, 0xCC))
                throw new Exception("Nao foi possivel instalar o hook temporario.");

            breakpointArmed = true;
            status = "ATIVO - recolorindo Ritmo musical";
            uint stepTid = 0;

            while (true) {
                // Only detach when no thread is in the middle of the single-step used
                // to execute the original first instruction.
                if (stopRequested && stepTid == 0) {
                    if (breakpointArmed) {
                        WriteByte(hp, target, original);
                        breakpointArmed = false;
                    }
                    status = "Desconectando com seguranca...";
                    break;
                }

                DEBUG_EVENT32 ev = new DEBUG_EVENT32();
                ev.Exception.ExceptionRecord.ExceptionInformation = new uint[15];

                if (!WaitForDebugEvent(ref ev, 50))
                    continue;

                uint cont = DBG_CONTINUE;
                bool exitAfterContinue = false;

                if (ev.dwDebugEventCode == EXCEPTION_DEBUG_EVENT) {
                    uint code = ev.Exception.ExceptionRecord.ExceptionCode;
                    uint addr = ev.Exception.ExceptionRecord.ExceptionAddress;

                    if (code == EXCEPTION_BREAKPOINT && addr == (uint)target.ToInt32()) {
                        IntPtr ht = OpenThread(
                            THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_QUERY_INFORMATION,
                            false, ev.dwThreadId);

                        if (ht != IntPtr.Zero) {
                            try {
                                CONTEXT ctx = NewContext();
                                if (GetThreadContext(ht, ref ctx)) {
                                    if (!stopRequested) {
                                        byte[] ptrBytes = new byte[4];
                                        IntPtr got;

                                        if (ReadProcessMemory(hp, new IntPtr((int)ctx.Esp + 8), ptrBytes, 4, out got)
                                            && got.ToInt32() == 4) {

                                            uint reportPtr = BitConverter.ToUInt32(ptrBytes, 0);
                                            if (reportPtr != 0) {
                                                byte[] report = new byte[64];
                                                if (ReadProcessMemory(hp, new IntPtr((int)reportPtr), report, 64, out got)
                                                    && got.ToInt32() == 64) {

                                                    if (RecolorReport(report)) {
                                                        IntPtr wrote;
                                                        WriteProcessMemory(hp, new IntPtr((int)reportPtr), report, 64, out wrote);
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // Temporarily restore the original instruction and single-step it.
                                    WriteByte(hp, target, original);
                                    breakpointArmed = false;
                                    ctx.Eip = (uint)target.ToInt32();
                                    ctx.EFlags |= 0x100;
                                    SetThreadContext(ht, ref ctx);
                                    stepTid = ev.dwThreadId;
                                }
                            }
                            finally {
                                CloseHandle(ht);
                            }
                        }
                    }
                    else if (code == EXCEPTION_SINGLE_STEP && ev.dwThreadId == stepTid) {
                        IntPtr ht = OpenThread(
                            THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_QUERY_INFORMATION,
                            false, ev.dwThreadId);

                        if (ht != IntPtr.Zero) {
                            try {
                                CONTEXT ctx = NewContext();
                                if (GetThreadContext(ht, ref ctx)) {
                                    ctx.EFlags &= ~0x100u;
                                    SetThreadContext(ht, ref ctx);
                                }
                            }
                            finally {
                                CloseHandle(ht);
                            }
                        }

                        stepTid = 0;

                        if (!stopRequested) {
                            WriteByte(hp, target, 0xCC);
                            breakpointArmed = true;
                        } else {
                            status = "Desconectando com seguranca...";
                            exitAfterContinue = true;
                        }
                    }
                    else {
                        if (code != EXCEPTION_BREAKPOINT)
                            cont = DBG_EXCEPTION_NOT_HANDLED;
                    }
                }
                else if (ev.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT) {
                    ContinueDebugEvent(ev.dwProcessId, ev.dwThreadId, DBG_CONTINUE);
                    status = "Software Redragon foi fechado";
                    attached = false;
                    break;
                }

                ContinueDebugEvent(ev.dwProcessId, ev.dwThreadId, cont);

                if (exitAfterContinue)
                    break;
            }
        }
        catch (Exception ex) {
            lastError = ex.Message;
            status = "ERRO: " + ex.Message;
        }
        finally {
            try {
                if (attached) {
                    if (hp != IntPtr.Zero && target != IntPtr.Zero && original != 0)
                        WriteByte(hp, target, original);

                    // We only reach here after all pending single-step work is finished.
                    DebugActiveProcessStop((uint)pid);
                }
            } catch (Exception ex2) {
                if (String.IsNullOrEmpty(lastError))
                    lastError = "Falha ao desanexar: " + ex2.Message;
            }

            if (hp != IntPtr.Zero)
                CloseHandle(hp);

            running = false;
            if (String.IsNullOrEmpty(lastError))
                status = "Parado com seguranca";
        }
    }
}
'@

    Log "Compilando hook..."
    Add-Type -TypeDefinition $source -Language CSharp
    Log "Compilacao OK."

    function Parse-HexColor([string]$text) {
        $t = $text.Trim().TrimStart('#')
        if ($t -notmatch '^[0-9A-Fa-f]{6}$') {
            throw "Cor invalida: $text"
        }
        return [Convert]::ToInt32($t, 16)
    }

    $configPath = Join-Path $PSScriptRoot "K552M-MusicPalette.json"

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "K552-M Studio 0.4"
    $form.Size = [System.Drawing.Size]::new(900, 820)
    $form.StartPosition = "CenterScreen"
    $form.MaximizeBox = $false
    $form.FormBorderStyle = "FixedDialog"

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "K552-M Studio 0.4"
    $title.Font = [System.Drawing.Font]::new("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $title.Location = [System.Drawing.Point]::new(18, 15)
    $title.Size = [System.Drawing.Size]::new(720, 30)
    $form.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Controle avancado de iluminacao para Redragon K552-M(PT)"
    $subtitle.ForeColor = [System.Drawing.Color]::DimGray
    $subtitle.Location = [System.Drawing.Point]::new(20, 44)
    $subtitle.Size = [System.Drawing.Size]::new(820, 22)
    $form.Controls.Add($subtitle)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = "Usa o Ritmo musical da Redragon como motor de audio e aplica efeitos, paletas, calibracao e perfis em tempo real."
    $info.Location = [System.Drawing.Point]::new(20, 68)
    $info.Size = [System.Drawing.Size]::new(835, 42)
    $form.Controls.Add($info)

    $paletteGroup = New-Object System.Windows.Forms.GroupBox
    $paletteGroup.Text = "Paleta"
    $paletteGroup.Location = [System.Drawing.Point]::new(18, 118)
    $paletteGroup.Size = [System.Drawing.Size]::new(385, 430)
    $form.Controls.Add($paletteGroup)

    $defaults = @("FF2FA0","A54DFF","4169FF","00E5FF","20FFB0","FFD23F")
    $checks = @()
    $texts = @()
    $buttons = @()

    function Update-ButtonColor($index) {
        try {
            $v = Parse-HexColor $texts[$index].Text
            $r = ($v -shr 16) -band 255
            $g = ($v -shr 8) -band 255
            $b = $v -band 255
            $buttons[$index].BackColor = [System.Drawing.Color]::FromArgb($r,$g,$b)
        } catch {}
    }

    for ($i=0; $i -lt 6; $i++) {
        $y = 28 + ($i * 43)

        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "Cor " + ($i + 1)
        $cb.Location = [System.Drawing.Point]::new(12, $y + 5)
        $cb.Size = [System.Drawing.Size]::new(65, 25)
        $cb.Checked = ($i -lt 4)
        $paletteGroup.Controls.Add($cb)
        $checks += $cb

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = $defaults[$i]
        $tb.Location = [System.Drawing.Point]::new(82, $y + 3)
        $tb.Size = [System.Drawing.Size]::new(92, 25)
        $paletteGroup.Controls.Add($tb)
        $texts += $tb

        $bt = New-Object System.Windows.Forms.Button
        $bt.Text = "Escolher"
        $bt.Location = [System.Drawing.Point]::new(185, $y)
        $bt.Size = [System.Drawing.Size]::new(125, 31)
        $paletteGroup.Controls.Add($bt)
        $buttons += $bt
    }

    $presetLabel = New-Object System.Windows.Forms.Label
    $presetLabel.Text = "Preset:"
    $presetLabel.Location = [System.Drawing.Point]::new(12, 298)
    $presetLabel.Size = [System.Drawing.Size]::new(60, 22)
    $paletteGroup.Controls.Add($presetLabel)

    $preset = New-Object System.Windows.Forms.ComboBox
    $preset.DropDownStyle = "DropDownList"
    [void]$preset.Items.Add("Cyberpunk")
    [void]$preset.Items.Add("Oceano")
    [void]$preset.Items.Add("Fogo")
    [void]$preset.Items.Add("Teste RGB")
    [void]$preset.Items.Add("Teste magenta")
    $preset.SelectedIndex = 0
    $preset.Location = [System.Drawing.Point]::new(72, 295)
    $preset.Size = [System.Drawing.Size]::new(145, 28)
    $paletteGroup.Controls.Add($preset)

    $applyPreset = New-Object System.Windows.Forms.Button
    $applyPreset.Text = "Aplicar"
    $applyPreset.Location = [System.Drawing.Point]::new(225, 293)
    $applyPreset.Size = [System.Drawing.Size]::new(85, 31)
    $paletteGroup.Controls.Add($applyPreset)

    $randomPalette = New-Object System.Windows.Forms.Button
    $randomPalette.Text = "Paleta aleatoria"
    $randomPalette.Location = [System.Drawing.Point]::new(12, 365)
    $randomPalette.Size = [System.Drawing.Size]::new(145, 30)
    $paletteGroup.Controls.Add($randomPalette)

    $reversePalette = New-Object System.Windows.Forms.Button
    $reversePalette.Text = "Inverter ordem"
    $reversePalette.Location = [System.Drawing.Point]::new(165, 365)
    $reversePalette.Size = [System.Drawing.Size]::new(145, 30)
    $paletteGroup.Controls.Add($reversePalette)

    $presetHelp = New-Object System.Windows.Forms.Label
    $presetHelp.Text = "Use 'Teste RGB' e 'Teste magenta' para avaliar o limite real das cores do teclado."
    $presetHelp.Location = [System.Drawing.Point]::new(12, 400)
    $presetHelp.Size = [System.Drawing.Size]::new(330, 28)
    $paletteGroup.Controls.Add($presetHelp)

    $controlGroup = New-Object System.Windows.Forms.GroupBox
    $controlGroup.Text = "Efeito e calibracao"
    $controlGroup.Location = [System.Drawing.Point]::new(420, 118)
    $controlGroup.Size = [System.Drawing.Size]::new(455, 430)
    $form.Controls.Add($controlGroup)

    $modeLabel = New-Object System.Windows.Forms.Label
    $modeLabel.Text = "Distribuicao:"
    $modeLabel.Location = [System.Drawing.Point]::new(15, 28)
    $modeLabel.Size = [System.Drawing.Size]::new(110, 22)
    $controlGroup.Controls.Add($modeLabel)

    $mode = New-Object System.Windows.Forms.ComboBox
    $mode.DropDownStyle = "DropDownList"
    [void]$mode.Items.Add("Remapear cores do efeito original")
    [void]$mode.Items.Add("Gradiente pela posicao")
    [void]$mode.Items.Add("Onda de paleta em movimento")
    [void]$mode.Items.Add("Ciclo global reativo")
    [void]$mode.Items.Add("Cor pela intensidade")
    [void]$mode.Items.Add("Remap + movimento")
    $mode.SelectedIndex = 0
    $mode.Location = [System.Drawing.Point]::new(15, 52)
    $mode.Size = [System.Drawing.Size]::new(405, 28)
    $controlGroup.Controls.Add($mode)

    $speedLabel = New-Object System.Windows.Forms.Label
    $speedLabel.Text = "Velocidade: 75%"
    $speedLabel.Location = [System.Drawing.Point]::new(15, 88)
    $speedLabel.Size = [System.Drawing.Size]::new(120, 22)
    $controlGroup.Controls.Add($speedLabel)

    $speed = New-Object System.Windows.Forms.TrackBar
    $speed.Minimum = 5
    $speed.Maximum = 300
    $speed.TickFrequency = 50
    $speed.Value = 75
    $speed.Location = [System.Drawing.Point]::new(135, 80)
    $speed.Size = [System.Drawing.Size]::new(300, 45)
    $controlGroup.Controls.Add($speed)

    $brightLabel = New-Object System.Windows.Forms.Label
    $brightLabel.Text = "Brilho: 100%"
    $brightLabel.Location = [System.Drawing.Point]::new(15, 132)
    $brightLabel.Size = [System.Drawing.Size]::new(120, 22)
    $controlGroup.Controls.Add($brightLabel)

    $brightness = New-Object System.Windows.Forms.TrackBar
    $brightness.Minimum = 25
    $brightness.Maximum = 150
    $brightness.TickFrequency = 25
    $brightness.Value = 100
    $brightness.Location = [System.Drawing.Point]::new(135, 124)
    $brightness.Size = [System.Drawing.Size]::new(280, 45)
    $controlGroup.Controls.Add($brightness)

    $satLabel = New-Object System.Windows.Forms.Label
    $satLabel.Text = "Saturacao: 100%"
    $satLabel.Location = [System.Drawing.Point]::new(15, 165)
    $satLabel.Size = [System.Drawing.Size]::new(120, 22)
    $controlGroup.Controls.Add($satLabel)

    $saturation = New-Object System.Windows.Forms.TrackBar
    $saturation.Minimum = 0
    $saturation.Maximum = 200
    $saturation.TickFrequency = 25
    $saturation.Value = 100
    $saturation.Location = [System.Drawing.Point]::new(135, 157)
    $saturation.Size = [System.Drawing.Size]::new(300, 45)
    $controlGroup.Controls.Add($saturation)

    $smoothLabel = New-Object System.Windows.Forms.Label
    $smoothLabel.Text = "Suavizacao: 0%"
    $smoothLabel.Location = [System.Drawing.Point]::new(15, 205)
    $smoothLabel.Size = [System.Drawing.Size]::new(120, 22)
    $controlGroup.Controls.Add($smoothLabel)

    $smoothing = New-Object System.Windows.Forms.TrackBar
    $smoothing.Minimum = 0
    $smoothing.Maximum = 90
    $smoothing.TickFrequency = 15
    $smoothing.Value = 0
    $smoothing.Location = [System.Drawing.Point]::new(135, 197)
    $smoothing.Size = [System.Drawing.Size]::new(300, 45)
    $controlGroup.Controls.Add($smoothing)

    $calTitle = New-Object System.Windows.Forms.Label
    $calTitle.Text = "Correcao dos canais (ajuda em roxo/ciano/amarelo):"
    $calTitle.Location = [System.Drawing.Point]::new(15, 245)
    $calTitle.Size = [System.Drawing.Size]::new(335, 22)
    $controlGroup.Controls.Add($calTitle)

    function Add-CalSlider([string]$name, [int]$y, [int]$value) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $name + ": " + $value + "%"
        $lbl.Location = [System.Drawing.Point]::new(15, $y)
        $lbl.Size = [System.Drawing.Size]::new(115, 22)
        $controlGroup.Controls.Add($lbl)

        $tr = New-Object System.Windows.Forms.TrackBar
        $tr.Minimum = 40
        $tr.Maximum = 200
        $tr.TickFrequency = 20
        $tr.Value = $value
        $tr.Location = [System.Drawing.Point]::new(130, $y - 8)
        $tr.Size = [System.Drawing.Size]::new(220, 45)
        $controlGroup.Controls.Add($tr)
        return @($lbl, $tr)
    }

    $redPair = Add-CalSlider "Vermelho" 275 100
    $redLabel = $redPair[0]; $redGain = $redPair[1]
    $greenPair = Add-CalSlider "Verde" 315 100
    $greenLabel = $greenPair[0]; $greenGain = $greenPair[1]
    $bluePair = Add-CalSlider "Azul" 355 100
    $blueLabel = $bluePair[0]; $blueGain = $bluePair[1]

    $gammaLabel = New-Object System.Windows.Forms.Label
    $gammaLabel.Text = "Curva: 1.00"
    $gammaLabel.Location = [System.Drawing.Point]::new(15, 395)
    $gammaLabel.Size = [System.Drawing.Size]::new(115, 22)
    $controlGroup.Controls.Add($gammaLabel)

    $gammaTrack = New-Object System.Windows.Forms.TrackBar
    $gammaTrack.Minimum = 50
    $gammaTrack.Maximum = 200
    $gammaTrack.TickFrequency = 25
    $gammaTrack.Value = 100
    $gammaTrack.Location = [System.Drawing.Point]::new(130, 387)
    $gammaTrack.Size = [System.Drawing.Size]::new(220, 45)
    $controlGroup.Controls.Add($gammaTrack)

    $resetCal = New-Object System.Windows.Forms.Button
    $resetCal.Text = "Resetar calibracao"
    $resetCal.Location = [System.Drawing.Point]::new(15, 412)
    $resetCal.Size = [System.Drawing.Size]::new(405, 28)
    $controlGroup.Controls.Add($resetCal)

    function Push-Config {
        try {
            $arr = New-Object System.Collections.Generic.List[int]
            for ($i=0; $i -lt 6; $i++) {
                if ($checks[$i].Checked) {
                    $arr.Add((Parse-HexColor $texts[$i].Text))
                }
            }
            if ($arr.Count -lt 2) { return }

            [K552PaletteHook]::SetPalette($arr.ToArray())
            [K552PaletteHook]::SetMode($mode.SelectedIndex)
            [K552PaletteHook]::SetSpeed($speed.Value / 100.0)
            [K552PaletteHook]::SetBrightness($brightness.Value / 100.0)
            [K552PaletteHook]::SetSaturation($saturation.Value / 100.0)
            [K552PaletteHook]::SetSmoothing($smoothing.Value / 100.0)
            [K552PaletteHook]::SetCalibration(
                $redGain.Value / 100.0,
                $greenGain.Value / 100.0,
                $blueGain.Value / 100.0,
                $gammaTrack.Value / 100.0)
        } catch {}
    }

    function Save-Config {
        try {
            $obj = [ordered]@{
                colors = @($texts | ForEach-Object { $_.Text })
                enabled = @($checks | ForEach-Object { $_.Checked })
                mode = $mode.SelectedIndex
                speed = $speed.Value
                brightness = $brightness.Value
                saturation = $saturation.Value
                smoothing = $smoothing.Value
                red = $redGain.Value
                green = $greenGain.Value
                blue = $blueGain.Value
                gamma = $gammaTrack.Value
                autoAttach = $autoAttach.Checked
            }
            ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $configPath -Encoding UTF8
        } catch {}
    }

    function Load-Config {
        if (-not (Test-Path -LiteralPath $configPath)) { return }
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

            for ($i=0; $i -lt 6; $i++) {
                if ($cfg.colors.Count -gt $i) { $texts[$i].Text = [string]$cfg.colors[$i] }
                if ($cfg.enabled.Count -gt $i) { $checks[$i].Checked = [bool]$cfg.enabled[$i] }
                Update-ButtonColor $i
            }

            if ($cfg.mode -ne $null -and $cfg.mode -ge 0 -and $cfg.mode -lt 6) { $mode.SelectedIndex = [int]$cfg.mode }
            if ($cfg.speed -ge 5 -and $cfg.speed -le 300) { $speed.Value = [int]$cfg.speed }
            if ($cfg.brightness -ge 25 -and $cfg.brightness -le 150) { $brightness.Value = [int]$cfg.brightness }
            if ($cfg.saturation -ge 0 -and $cfg.saturation -le 200) { $saturation.Value = [int]$cfg.saturation }
            if ($cfg.smoothing -ge 0 -and $cfg.smoothing -le 90) { $smoothing.Value = [int]$cfg.smoothing }
            if ($cfg.red -ge 40 -and $cfg.red -le 200) { $redGain.Value = [int]$cfg.red }
            if ($cfg.green -ge 40 -and $cfg.green -le 200) { $greenGain.Value = [int]$cfg.green }
            if ($cfg.blue -ge 40 -and $cfg.blue -le 200) { $blueGain.Value = [int]$cfg.blue }
            if ($cfg.gamma -ge 50 -and $cfg.gamma -le 200) { $gammaTrack.Value = [int]$cfg.gamma }
            if ($cfg.autoAttach -ne $null) { $autoAttach.Checked = [bool]$cfg.autoAttach }
        } catch {
            Log ("Config ignorada: " + $_.Exception.Message)
        }
    }

    for ($i=0; $i -lt 6; $i++) {
        Update-ButtonColor $i
        $buttons[$i].Tag = $i

        $buttons[$i].Add_Click({
            $j = [int]$this.Tag
            $dlg = New-Object System.Windows.Forms.ColorDialog
            try {
                $v = Parse-HexColor $texts[$j].Text
                $dlg.Color = [System.Drawing.Color]::FromArgb(
                    (($v -shr 16) -band 255),
                    (($v -shr 8) -band 255),
                    ($v -band 255))
            } catch {}

            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $texts[$j].Text = ("{0:X2}{1:X2}{2:X2}" -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)
                Update-ButtonColor $j
                Push-Config
            }
        })

        $texts[$i].Add_TextChanged({
            Update-ButtonColor ([array]::IndexOf($texts, $this))
            Push-Config
        })
        $checks[$i].Add_CheckedChanged({ Push-Config })
    }

    $applyPreset.Add_Click({
        $sets = @{
            "Cyberpunk"    = @("FF2FA0","A54DFF","4169FF","00E5FF")
            "Oceano"       = @("003CFF","00A8FF","00FFF0","00FF8C")
            "Fogo"         = @("FF1700","FF5A00","FFB000","FFF000")
            "Teste RGB"    = @("FF0000","00FF00","0000FF","FFFFFF")
            "Teste magenta"= @("FF00FF","FF00FF")
        }
        $vals = $sets[[string]$preset.SelectedItem]
        if ($vals) {
            for ($i=0; $i -lt 6; $i++) {
                if ($i -lt $vals.Count) {
                    $texts[$i].Text = $vals[$i]
                    $checks[$i].Checked = $true
                } else {
                    $checks[$i].Checked = $false
                }
                Update-ButtonColor $i
            }
            Push-Config
        }
    })

    $randomPalette.Add_Click({
        $rng = New-Object System.Random
        for ($i=0; $i -lt 6; $i++) {
            $r = $rng.Next(32,256)
            $g = $rng.Next(32,256)
            $b = $rng.Next(32,256)
            $texts[$i].Text = ("{0:X2}{1:X2}{2:X2}" -f $r,$g,$b)
            $checks[$i].Checked = ($i -lt 4)
            Update-ButtonColor $i
        }
        Push-Config
    })

    $reversePalette.Add_Click({
        $vals = @($texts | ForEach-Object { $_.Text })
        $flags = @($checks | ForEach-Object { $_.Checked })
        [array]::Reverse($vals)
        [array]::Reverse($flags)
        for ($i=0; $i -lt 6; $i++) {
            $texts[$i].Text = $vals[$i]
            $checks[$i].Checked = $flags[$i]
            Update-ButtonColor $i
        }
        Push-Config
    })

    $mode.Add_SelectedIndexChanged({ Push-Config })

    $speed.Add_ValueChanged({
        $speedLabel.Text = "Velocidade: " + $speed.Value + "%"
        Push-Config
    })

    $brightness.Add_ValueChanged({
        $brightLabel.Text = "Brilho: " + $brightness.Value + "%"
        Push-Config
    })

    $saturation.Add_ValueChanged({
        $satLabel.Text = "Saturacao: " + $saturation.Value + "%"
        Push-Config
    })

    $smoothing.Add_ValueChanged({
        $smoothLabel.Text = "Suavizacao: " + $smoothing.Value + "%"
        Push-Config
    })

    $redGain.Add_ValueChanged({
        $redLabel.Text = "Vermelho: " + $redGain.Value + "%"
        Push-Config
    })
    $greenGain.Add_ValueChanged({
        $greenLabel.Text = "Verde: " + $greenGain.Value + "%"
        Push-Config
    })
    $blueGain.Add_ValueChanged({
        $blueLabel.Text = "Azul: " + $blueGain.Value + "%"
        Push-Config
    })
    $gammaTrack.Add_ValueChanged({
        $gammaLabel.Text = ("Curva: {0:N2}" -f ($gammaTrack.Value / 100.0))
        Push-Config
    })

    $resetCal.Add_Click({
        $redGain.Value = 100
        $greenGain.Value = 100
        $blueGain.Value = 100
        $gammaTrack.Value = 100
        Push-Config
    })

    $profilesDir = Join-Path $PSScriptRoot "Profiles"
    if (-not (Test-Path -LiteralPath $profilesDir)) {
        New-Item -ItemType Directory -Path $profilesDir | Out-Null
    }

    function Get-SettingsObject {
        return [ordered]@{
            colors = @($texts | ForEach-Object { $_.Text })
            enabled = @($checks | ForEach-Object { $_.Checked })
            mode = $mode.SelectedIndex
            speed = $speed.Value
            brightness = $brightness.Value
            saturation = $saturation.Value
            smoothing = $smoothing.Value
            red = $redGain.Value
            green = $greenGain.Value
            blue = $blueGain.Value
            gamma = $gammaTrack.Value
        }
    }

    function Apply-SettingsObject($cfg) {
        for ($i=0; $i -lt 6; $i++) {
            if ($cfg.colors.Count -gt $i) { $texts[$i].Text = [string]$cfg.colors[$i] }
            if ($cfg.enabled.Count -gt $i) { $checks[$i].Checked = [bool]$cfg.enabled[$i] }
            Update-ButtonColor $i
        }
        if ($cfg.mode -ne $null -and $cfg.mode -ge 0 -and $cfg.mode -lt 6) { $mode.SelectedIndex = [int]$cfg.mode }
        if ($cfg.speed -ge 5 -and $cfg.speed -le 300) { $speed.Value = [int]$cfg.speed }
        if ($cfg.brightness -ge 25 -and $cfg.brightness -le 150) { $brightness.Value = [int]$cfg.brightness }
        if ($cfg.saturation -ge 0 -and $cfg.saturation -le 200) { $saturation.Value = [int]$cfg.saturation }
        if ($cfg.smoothing -ge 0 -and $cfg.smoothing -le 90) { $smoothing.Value = [int]$cfg.smoothing }
        if ($cfg.red -ge 40 -and $cfg.red -le 200) { $redGain.Value = [int]$cfg.red }
        if ($cfg.green -ge 40 -and $cfg.green -le 200) { $greenGain.Value = [int]$cfg.green }
        if ($cfg.blue -ge 40 -and $cfg.blue -le 200) { $blueGain.Value = [int]$cfg.blue }
        if ($cfg.gamma -ge 50 -and $cfg.gamma -le 200) { $gammaTrack.Value = [int]$cfg.gamma }
        Push-Config
    }

    $profileGroup = New-Object System.Windows.Forms.GroupBox
    $profileGroup.Text = "Perfis"
    $profileGroup.Location = [System.Drawing.Point]::new(18, 565)
    $profileGroup.Size = [System.Drawing.Size]::new(857, 82)
    $form.Controls.Add($profileGroup)

    $profileName = New-Object System.Windows.Forms.TextBox
    $profileName.Text = "Meu perfil"
    $profileName.Location = [System.Drawing.Point]::new(12, 32)
    $profileName.Size = [System.Drawing.Size]::new(175, 25)
    $profileGroup.Controls.Add($profileName)

    $profileList = New-Object System.Windows.Forms.ComboBox
    $profileList.DropDownStyle = "DropDownList"
    $profileList.Location = [System.Drawing.Point]::new(200, 30)
    $profileList.Size = [System.Drawing.Size]::new(250, 28)
    $profileGroup.Controls.Add($profileList)

    $saveProfile = New-Object System.Windows.Forms.Button
    $saveProfile.Text = "Salvar perfil"
    $saveProfile.Location = [System.Drawing.Point]::new(465, 28)
    $saveProfile.Size = [System.Drawing.Size]::new(100, 31)
    $profileGroup.Controls.Add($saveProfile)

    $loadProfile = New-Object System.Windows.Forms.Button
    $loadProfile.Text = "Carregar"
    $loadProfile.Location = [System.Drawing.Point]::new(575, 28)
    $loadProfile.Size = [System.Drawing.Size]::new(95, 31)
    $profileGroup.Controls.Add($loadProfile)

    $deleteProfile = New-Object System.Windows.Forms.Button
    $deleteProfile.Text = "Excluir"
    $deleteProfile.Location = [System.Drawing.Point]::new(680, 28)
    $deleteProfile.Size = [System.Drawing.Size]::new(95, 31)
    $profileGroup.Controls.Add($deleteProfile)

    function Refresh-Profiles {
        $profileList.Items.Clear()
        Get-ChildItem -LiteralPath $profilesDir -Filter *.json -ErrorAction SilentlyContinue |
            Sort-Object Name | ForEach-Object {
                [void]$profileList.Items.Add($_.BaseName)
            }
        if ($profileList.Items.Count -gt 0 -and $profileList.SelectedIndex -lt 0) {
            $profileList.SelectedIndex = 0
        }
    }

    $saveProfile.Add_Click({
        $name = ($profileName.Text -replace '[\\/:*?"<>|]', '_').Trim()
        if (-not $name) { return }
        $path = Join-Path $profilesDir ($name + ".json")
        (Get-SettingsObject | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
        Refresh-Profiles
        $profileList.SelectedItem = $name
        Log ("Perfil salvo: " + $name)
    })

    $loadProfile.Add_Click({
        if (-not $profileList.SelectedItem) { return }
        $path = Join-Path $profilesDir ([string]$profileList.SelectedItem + ".json")
        if (Test-Path -LiteralPath $path) {
            $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            Apply-SettingsObject $cfg
            Log ("Perfil carregado: " + [string]$profileList.SelectedItem)
        }
    })

    $deleteProfile.Add_Click({
        if (-not $profileList.SelectedItem) { return }
        $path = Join-Path $profilesDir ([string]$profileList.SelectedItem + ".json")
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Refresh-Profiles
        }
    })

    Refresh-Profiles

    $openRedragon = New-Object System.Windows.Forms.Button
    $openRedragon.Text = "ABRIR REDRAGON"
    $openRedragon.Location = [System.Drawing.Point]::new(335, 665)
    $openRedragon.Size = [System.Drawing.Size]::new(170, 45)
    $form.Controls.Add($openRedragon)

    $autoAttach = New-Object System.Windows.Forms.CheckBox
    $autoAttach.Text = "Auto-ativar ao detectar o software Redragon"
    $autoAttach.Location = [System.Drawing.Point]::new(20, 705)
    $autoAttach.Size = [System.Drawing.Size]::new(300, 25)
    $form.Controls.Add($autoAttach)

    $start = New-Object System.Windows.Forms.Button
    $start.Text = "ATIVAR"
    $start.Font = [System.Drawing.Font]::new("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $start.Location = [System.Drawing.Point]::new(515, 665)
    $start.Size = [System.Drawing.Size]::new(180, 45)
    $form.Controls.Add($start)

    $stop = New-Object System.Windows.Forms.Button
    $stop.Text = "PARAR COM SEGURANCA"
    $stop.Location = [System.Drawing.Point]::new(695, 665)
    $stop.Size = [System.Drawing.Size]::new(180, 45)
    $form.Controls.Add($stop)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = "Status: Parado"
    $status.Font = [System.Drawing.Font]::new("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $status.Location = [System.Drawing.Point]::new(20, 670)
    $status.Size = [System.Drawing.Size]::new(340, 50)
    $form.Controls.Add($status)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = "Dica: use perfis para salvar paletas e calibracoes diferentes. A suavizacao reduz piscadas bruscas; saturacao acima de 100% deixa as cores mais fortes."
    $note.Location = [System.Drawing.Point]::new(20, 730)
    $note.Size = [System.Drawing.Size]::new(850, 42)
    $form.Controls.Add($note)

    $redragonPath = Join-Path $PSScriptRoot "redragon-path.txt"

    $openRedragon.Add_Click({
        try {
            if (Test-Path -LiteralPath $redragonPath) {
                $p = (Get-Content -LiteralPath $redragonPath -Raw).Trim()
                if ($p -and (Test-Path -LiteralPath $p)) {
                    Start-Process -FilePath $p
                    return
                }
            }

            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = "Executavel Redragon (*.exe)|*.exe"
            $dlg.Title = "Selecione Redragon K552-M(PT).exe"

            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $dlg.FileName | Set-Content -LiteralPath $redragonPath -Encoding UTF8
                Start-Process -FilePath $dlg.FileName
            }
        } catch {
            Log ("Abrir Redragon: " + $_.Exception.Message)
        }
    })

    $start.Add_Click({
        try {
            $enabled = @()
            for ($i=0; $i -lt 6; $i++) {
                if ($checks[$i].Checked) { $enabled += $i }
            }
            if ($enabled.Count -lt 2) {
                [System.Windows.Forms.MessageBox]::Show("Ative pelo menos 2 cores.", "K552-M") | Out-Null
                return
            }

            Push-Config
            Save-Config

            $proc = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.ProcessName -like "Redragon K552-M*"
            } | Select-Object -First 1

            if (-not $proc) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Abra primeiro o software oficial Redragon K552-M(PT).",
                    "K552-M") | Out-Null
                return
            }

            Log ("Iniciando hook no PID " + $proc.Id)
            [K552PaletteHook]::Start($proc.Id)
        }
        catch {
            Log ("ERRO Start: " + $_.Exception.ToString())
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Erro") | Out-Null
        }
    })

    $stop.Add_Click({
        Log "Solicitado stop seguro..."
        $stop.Enabled = $false
        [K552PaletteHook]::Stop()
        Log ("Stop finalizado. Status: " + [K552PaletteHook]::Status)
    })

    $lastLoggedError = ""
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        $status.Text = "Status: " + [K552PaletteHook]::Status
        $start.Enabled = -not [K552PaletteHook]::IsRunning
        $stop.Enabled = [K552PaletteHook]::IsRunning

        if ($autoAttach.Checked -and -not [K552PaletteHook]::IsRunning) {
            $pauto = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.ProcessName -like "Redragon K552-M*"
            } | Select-Object -First 1

            if ($pauto) {
                Push-Config
                [K552PaletteHook]::Start($pauto.Id)
            }
        }

        $errNow = [K552PaletteHook]::LastError
        if ($errNow -and $errNow -ne $lastLoggedError) {
            $lastLoggedError = $errNow
            Log ("Hook: " + $errNow)
        }
    })
    $timer.Start()

    Load-Config
    Push-Config

    $form.Add_FormClosing({
        try {
            Save-Config
            $timer.Stop()
            [K552PaletteHook]::Stop()
        } catch {}
    })

    [void]$form.ShowDialog()
}
catch {
    Log ("FATAL: " + $_.Exception.ToString())
    [System.Windows.Forms.MessageBox]::Show(
        "Erro: " + $_.Exception.Message + "`r`n`r`nVeja K552M-MusicPalette.log",
        "K552-M Music Palette") | Out-Null
    exit 1
}
