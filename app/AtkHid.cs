// ATK X1 Ultimate 2.0 pil okuyucu.
// Protokol ATK HUB'dan (COMPX ailesi) alinmistir:
//   arayuz : ureticiye ozel koleksiyon, 17 baytlik giris/cikis raporu (X1 Ultimate 2.0: MI_01, FF02/Usage 2)
//   istek  : rapor 8, 16 bayt [komut, durum, adres(2), uzunluk, veri(10), saglama]
//            GetBatteryLevel = 4, saglama = 0x55 - (8 + ilk 15 baytin toplami)
//   yanit  : rapor 8, veri[5] = pil %, veri[6] = sarj durumu, veri[7..8] = voltaj (mV)
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

// Windows'un USB "cihaz takildi" bildirimini (WM_DEVICECHANGE) dinler. Yoklama yapmaz, olay kacmaz.
// Mesajlar, ayni thread'deki WPF Dispatcher dongusu tarafindan pompalanir.
public class AtkDeviceWatcher : System.Windows.Forms.NativeWindow, IDisposable
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEV_BROADCAST_DEVICEINTERFACE
    {
        public int dbcc_size, dbcc_devicetype, dbcc_reserved;
        public Guid dbcc_classguid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 255)] public string dbcc_name;
    }
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterDeviceNotification(IntPtr hRecipient, ref DEV_BROADCAST_DEVICEINTERFACE filter, int flags);
    [DllImport("user32.dll")] static extern bool UnregisterDeviceNotification(IntPtr handle);

    const int WM_DEVICECHANGE = 0x219, DBT_DEVICEARRIVAL = 0x8000, DBT_DEVTYP_DEVICEINTERFACE = 5;
    static readonly Guid GUID_DEVINTERFACE_USB_DEVICE = new Guid("A5DCBF10-6530-11D2-901F-00C04FB951ED");

    readonly string[] filters;
    readonly ConcurrentQueue<string> arrivals = new ConcurrentQueue<string>();
    IntPtr notifyHandle;

    // filter: aygit yolunda aranacak metin(ler), '|' ile ayrilir (orn. "vid_373b|vid_3554"); bos = tum USB cihazlari
    public AtkDeviceWatcher(string filter)
    {
        this.filters = (filter ?? "").ToLowerInvariant().Split(new[] { '|' }, StringSplitOptions.RemoveEmptyEntries);
        CreateHandle(new System.Windows.Forms.CreateParams());
        var f = new DEV_BROADCAST_DEVICEINTERFACE();
        f.dbcc_size = Marshal.SizeOf(f);
        f.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
        f.dbcc_classguid = GUID_DEVINTERFACE_USB_DEVICE;
        notifyHandle = RegisterDeviceNotification(Handle, ref f, 0);
        if (notifyHandle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    protected override void WndProc(ref System.Windows.Forms.Message m)
    {
        if (m.Msg == WM_DEVICECHANGE && m.WParam.ToInt64() == DBT_DEVICEARRIVAL && m.LParam != IntPtr.Zero
            && Marshal.ReadInt32(m.LParam, 4) == DBT_DEVTYP_DEVICEINTERFACE)
        {
            string name = Marshal.PtrToStringUni(new IntPtr(m.LParam.ToInt64() + 28));   // dbcc_name
            if (name != null && Matches(name.ToLowerInvariant())) arrivals.Enqueue(name);
        }
        base.WndProc(ref m);
    }

    bool Matches(string lowerName)
    {
        if (filters.Length == 0) return true;
        foreach (string f in filters) if (lowerName.Contains(f)) return true;
        return false;
    }

    public string TakeArrival() { string s; return arrivals.TryDequeue(out s) ? s : null; }

    public void Dispose()
    {
        if (notifyHandle != IntPtr.Zero) { UnregisterDeviceNotification(notifyHandle); notifyHandle = IntPtr.Zero; }
        DestroyHandle();
    }
}

public class AtkBattery
{
    public int Level;
    public int Charge;      // ham sarj durumu bayti
    public int VoltageMv;
    public string Path;
    public string Raw;      // ham yanit (hex) - hata ayiklama icin
    public bool ChecksumOk; // yanitin saglama bayti dogru mu (ATK HUB kontrol etmez, bilgi amacli)
    // ATK HUB ile ayni: yalnizca 1 = sarj oluyor (aYt.charging = 1)
    public bool IsCharging { get { return Charge == 1; } }
}

public static class AtkHid
{
    public const byte ReportId = 8;
    public const byte CmdGetBatteryLevel = 4;
    const int PacketSize = 16;   // rapor numarasi haric

    // 17 baytlik cikis raporu: [rapor 8][komut, durum, adres(2), uzunluk, veri(10), saglama]
    public static byte[] BuildRequest(byte command, int reportLength)
    {
        byte[] buf = new byte[Math.Max(reportLength, PacketSize + 1)];
        buf[0] = ReportId;
        buf[1] = command;
        buf[PacketSize] = Checksum(buf);
        return buf;
    }

    // 0x55 - (rapor no + paketin ilk 15 bayti); mouse yanitlari da ayni formulu kullanir
    public static byte Checksum(byte[] report)
    {
        int sum = ReportId;
        for (int i = 1; i < PacketSize; i++) sum += report[i];
        return (byte)((0x55 - (sum & 0xFF)) & 0xFF);
    }

    // Giris raporunu cozer; pil yaniti degilse null doner
    public static AtkBattery ParseBatteryResponse(byte[] buf, int length)
    {
        if (buf == null || length < 10 || buf.Length < 10) return null;
        if (buf[0] != ReportId || buf[1] != CmdGetBatteryLevel) return null;
        return new AtkBattery
        {
            Level = Math.Min(100, (int)buf[6]),
            Charge = buf[7],
            VoltageMv = (buf[8] << 8) | buf[9],
            Raw = BitConverter.ToString(buf, 0, Math.Min(length, PacketSize + 1)),
            ChecksumOk = length > PacketSize && buf.Length > PacketSize && buf[PacketSize] == Checksum(buf)
        };
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS
    {
        public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
                      NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
                      NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr pp);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr pp, out HIDP_CAPS caps);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerator, IntPtr hwnd, int flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g, int idx, ref SP_DEVICE_INTERFACE_DATA d);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int required, IntPtr devInfo);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);

    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000, FILE_SHARE_RW = 3, OPEN_EXISTING = 3, FILE_FLAG_OVERLAPPED = 0x40000000;
    const int DIGCF_PRESENT = 2, DIGCF_DEVICEINTERFACE = 0x10;

    static List<string> HidPaths()
    {
        var list = new List<string>();
        Guid g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        try
        {
            var d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
            for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d); i++)
            {
                int req; SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                IntPtr buf = Marshal.AllocHGlobal(req);
                try
                {
                    Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                    if (SetupDiGetDeviceInterfaceDetail(set, ref d, buf, req, out req, IntPtr.Zero))
                        list.Add(Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4)));
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return list;
    }

    // Takili HID cihazlarinin kimlikleri, orn. "vid_373b&pid_11e7" (tekrarsiz)
    public static List<string> PresentDevices()
    {
        var ids = new List<string>();
        foreach (string path in HidPaths())
        {
            var m = Regex.Match(path.ToLowerInvariant(), "vid_[0-9a-f]{4}&pid_[0-9a-f]{4}");
            if (m.Success && !ids.Contains(m.Value)) ids.Add(m.Value);
        }
        return ids;
    }

    // Arka planda, cihaz hazir olana kadar birkac kez dener (UI'yi bloklamaz)
    public static Task<AtkBattery> ReadBatteryAsync(string deviceFilter, int timeoutMs, int attempts, int delayMs)
    {
        return Task.Run(() =>
        {
            for (int i = 0; i < attempts; i++)
            {
                try { var b = ReadBattery(deviceFilter, timeoutMs); if (b != null) return b; } catch { }
                System.Threading.Thread.Sleep(delayMs);
            }
            return (AtkBattery)null;
        });
    }

    // deviceFilter ornek: "vid_373b&pid_11e7" (mouse kablolu) ya da "vid_373b&pid_11d9" (alici)
    public static AtkBattery ReadBattery(string deviceFilter, int timeoutMs)
    {
        string filter = deviceFilter.ToLowerInvariant();
        // ATK HUB cihazi tanimlayici bir koleksiyonla (orn. 0xFF04) secer; Windows'ta ise 8 numarali 16 baytlik
        // rapor ayni arayuzdeki baska bir ureticiye ozel koleksiyondadir (X1 Ultimate 2.0'da 0xFF02).
        // Bu yuzden 17 baytlik giris/cikis raporu olan ureticiye ozel koleksiyonlar sirayla denenir.
        foreach (string path in HidPaths())
        {
            if (!path.ToLowerInvariant().Contains(filter)) continue;
            using (SafeFileHandle h = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_RW, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero))
            {
                if (h.IsInvalid) continue;   // fare/klavye koleksiyonlarini Windows ozel acar, atlanir
                IntPtr pp; if (!HidD_GetPreparsedData(h, out pp)) continue;
                HIDP_CAPS caps; HidP_GetCaps(pp, out caps); HidD_FreePreparsedData(pp);
                if (caps.UsagePage < 0xFF00 || caps.OutputReportByteLength != PacketSize + 1 || caps.InputReportByteLength != PacketSize + 1) continue;

                var result = Query(h, caps, timeoutMs);
                if (result != null) { result.Path = path; return result; }
            }
        }
        return null;
    }

    static AtkBattery Query(SafeFileHandle h, HIDP_CAPS caps, int timeoutMs)
    {
        using (var fs = new FileStream(h, FileAccess.ReadWrite, 1, true))
        {
            byte[] outBuf = BuildRequest(CmdGetBatteryLevel, caps.OutputReportByteLength);
            fs.Write(outBuf, 0, outBuf.Length);

            var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            byte[] inBuf = new byte[caps.InputReportByteLength];
            while (DateTime.UtcNow < deadline)
            {
                Task<int> t = fs.ReadAsync(inBuf, 0, inBuf.Length);
                int left = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                if (left <= 0 || !t.Wait(left)) return null;   // zaman asimi (handle kapaninca okuma iptal olur)
                var battery = ParseBatteryResponse(inBuf, t.Result);   // baska raporlar (orn. DPI degisimi) atlanir
                if (battery != null) return battery;
            }
        }
        return null;
    }
}
