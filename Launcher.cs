using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("P4 Auto Merge")]
[assembly: AssemblyDescription("P4 auto merge with safe resolve and manual conflict handling")]
[assembly: AssemblyProduct("P4 Auto Merge")]
[assembly: AssemblyVersion("1.0.1.0")]
[assembly: AssemblyFileVersion("1.0.1.0")]
[assembly: AssemblyInformationalVersion("1.0.1")]

internal static class Program
{
    private const string GuiName = "P4AutoMerge.ps1";
    private const string CoreName = "P4AutoMerge.Core.psm1";
    private const int ExtractTimeoutMs = 15000;
    private const string RunningMutex = "Local\\FlamesTools.P4AutoMerge.Running";
    private static readonly Encoding Utf8 = new UTF8Encoding(false);

    [STAThread]
    private static int Main(string[] args)
    {
        bool diagnostic = args.Length != 0;
        try
        {
            return RunApplication(args);
        }
        catch (Exception error)
        {
            string path = SaveDiagnostic(error.ToString());
            if (diagnostic)
                WriteDiagnosticOutput(error.Message + Environment.NewLine + path, true);
            else
                MessageBox.Show("工具启动失败：" + error.Message + "\n\n诊断记录：" + path,
                    "P4 自动合并", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static int RunApplication(string[] args)
    {
        using (Mutex lifetime = new Mutex(false, RunningMutex))
        {
            string mode = GetMode(args);
            return RunTool(PrepareRuntime(), mode);
        }
    }

    private static string GetMode(string[] args)
    {
        if (args.Length == 0) return String.Empty;
        if (args.Length == 1 && (args[0] == "-HeadlessTest" || args[0] == "-ReadOnlyStartupTest"))
            return args[0];
        throw new ArgumentException("不支持此启动参数。");
    }

    private static string GetUserRoot()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FlamesTools", "P4AutoMerge");
    }

    private static byte[] ReadResource(string name)
    {
        using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (resource == null) throw new InvalidDataException("缺少内置文件：" + name);
            using (MemoryStream bytes = new MemoryStream())
            {
                resource.CopyTo(bytes);
                return bytes.ToArray();
            }
        }
    }

    private static string GetDigest(byte[] bytes)
    {
        using (SHA256 hash = SHA256.Create())
            return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", String.Empty);
    }

    private static string PrepareRuntime()
    {
        byte[] gui = ReadResource(GuiName);
        byte[] core = ReadResource(CoreName);
        string identity = GetDigest(Utf8.GetBytes(GetDigest(gui) + GetDigest(core)));
        string root = Path.Combine(GetUserRoot(), "Runtime", identity);
        using (Mutex gate = new Mutex(false, "Local\\P4AutoMerge.Package." + identity))
        {
            bool held = false;
            try
            {
                try { held = gate.WaitOne(ExtractTimeoutMs); }
                catch (AbandonedMutexException) { held = true; }
                if (!held) throw new TimeoutException("其他窗口正在准备此版本，请稍后重新打开。");
                Directory.CreateDirectory(root);
                WriteResource(Path.Combine(root, GuiName), gui);
                WriteResource(Path.Combine(root, CoreName), core);
            }
            finally { if (held) gate.ReleaseMutex(); }
        }
        return root;
    }

    private static void WriteResource(string path, byte[] bytes)
    {
        if (File.Exists(path) && GetDigest(File.ReadAllBytes(path)) == GetDigest(bytes)) return;
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, bytes);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static ProcessStartInfo CreateStartInfo(string root, string mode)
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string shell = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(shell)) throw new FileNotFoundException("需要 Windows PowerShell 5.1。", shell);
        return new ProcessStartInfo
        {
            FileName = shell,
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" +
                Path.Combine(root, GuiName) + "\" " + mode,
            WorkingDirectory = root,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8
        };
    }

    private static int RunTool(string root, string mode)
    {
        using (Process child = new Process())
        {
            child.StartInfo = CreateStartInfo(root, mode);
            if (!child.Start()) throw new IOException("无法启动工具界面。");
            var output = child.StandardOutput.ReadToEndAsync();
            var errors = child.StandardError.ReadToEndAsync();
            child.WaitForExit();
            string report = output.Result + errors.Result;
            if (mode.Length != 0)
            {
                WriteDiagnosticOutput(report + "Diagnostic log: " + SaveDiagnostic(report), false);
            }
            if (child.ExitCode != 0) throw new InvalidOperationException("工具退出码 " + child.ExitCode + "\n" + report);
            return 0;
        }
    }

    private static void WriteDiagnosticOutput(string text, bool error)
    {
        byte[] bytes = Utf8.GetBytes(text + Environment.NewLine);
        Stream output = error ? Console.OpenStandardError() : Console.OpenStandardOutput();
        output.Write(bytes, 0, bytes.Length);
        output.Flush();
    }

    private static string SaveDiagnostic(string text)
    {
        try
        {
            string directory = Path.Combine(GetUserRoot(), "Diagnostics");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "launcher-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") +
                "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".log");
            File.WriteAllText(path, text, Utf8);
            return path;
        }
        catch { return "无法写入诊断记录。"; }
    }
}
