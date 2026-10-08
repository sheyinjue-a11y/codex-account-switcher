using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class WindowsLauncher {
    [STAThread]
    private static int Main(string[] args) {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string entry = Path.Combine(root, "app", "tools", "chatgpt-account-switch", "Open-Switcher.ps1");
        bool verify = args.Length == 1 && args[0] == "--verify-layout";
        if (!File.Exists(entry)) {
            if (!verify) MessageBox.Show("请先完整解压下载包，再打开 Codex Account Switcher。请保留旁边的 app 文件夹。", "Codex Account Switcher", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 2;
        }
        if (verify) return 0;
        try {
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            var info = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + entry + "\"");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = root;
            Process.Start(info).Dispose();
            return 0;
        } catch {
            MessageBox.Show("未能打开切换器。请确认 Windows PowerShell 可用，并完整解压下载包。", "Codex Account Switcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
