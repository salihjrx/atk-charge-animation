// ATK Charge Animation baslaticisi.
// Programin tek giris noktasidir; kendisi is yapmaz, app\ klasorundeki PowerShell betiklerini
// kendi surecinde (konsol penceresi olmadan) calistirir.
//
//   ATK Charge Animation.exe             -> kontrol merkezi   (app\ayarlar.ps1)
//   ATK Charge Animation.exe --watcher   -> arka plan izleyici (app\atk-sarj.ps1)
//
// Derleme: app\tools\build-launcher.ps1
using System;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("ATK Charge Animation")]
[assembly: AssemblyProduct("ATK Charge Animation")]
[assembly: AssemblyDescription("Charging animation and battery notifications for ATK mice")]
[assembly: AssemblyCopyright("Copyright (c) 2026 salihjrx")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        bool turkish = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "tr";
        string exeDir = AppDomain.CurrentDomain.BaseDirectory;
        string appDir = Path.Combine(exeDir, "app");
        bool watcher = args.Length > 0 && args[0].Equals("--watcher", StringComparison.OrdinalIgnoreCase);
        string script = Path.Combine(appDir, watcher ? "atk-sarj.ps1" : "ayarlar.ps1");

        if (!File.Exists(script))
        {
            // Genellikle ZIP icinden calistirildiginda olur: app klasoru yanina cikarilmamistir
            if (!watcher)
                MessageBox.Show(turkish
                    ? "Programın dosyaları bulunamadı.\n\nLütfen önce indirdiğiniz ZIP dosyasını bir klasöre çıkarın ve uygulamayı o klasörden çalıştırın."
                    : "The program files could not be found.\n\nPlease extract the downloaded ZIP file to a folder first and run the application from there.",
                    "ATK Charge Animation", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 1;
        }

        try
        {
            // Betikler bu surecin icinde, WPF icin STA thread'de calisir. Calistirma ilkesi yalnizca bu surec icin gevsetilir.
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    ps.Invoke();
                    if (ps.HadErrors) ReportErrors(ps, appDir);
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            WriteCrashLog(appDir, ex.ToString());
            if (!watcher)
                MessageBox.Show((turkish ? "Program başlatılamadı:\n\n" : "The program could not start:\n\n") + ex.Message,
                    "ATK Charge Animation", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }

    static void ReportErrors(PowerShell ps, string appDir)
    {
        var sb = new StringBuilder();
        foreach (ErrorRecord e in ps.Streams.Error) sb.AppendLine(e.ToString());
        WriteCrashLog(appDir, sb.ToString());
    }

    static void WriteCrashLog(string appDir, string text)
    {
        try { File.AppendAllText(Path.Combine(appDir, "hata-log.txt"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\r\n" + text + "\r\n", Encoding.UTF8); }
        catch { }
    }
}
