@echo off
setlocal EnableExtensions
set "RB_SCRIPT=%~f0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "try { $src=Get-Content -LiteralPath $env:RB_SCRIPT -Raw -Encoding UTF8; $body=($src -split '(?m)^# POWERSHELL BELOW\r?$',2)[1]; if (-not $body) { throw 'PowerShell section not found' }; & ([scriptblock]::Create($body)) } catch { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show($_.Exception.Message, 'Russian Banks') | Out-Null } finally { $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\'); $tempBat=[IO.Path]::GetFullPath($env:RB_SCRIPT); $tempDir=[IO.Path]::GetDirectoryName($tempBat); if ([string]::Equals([IO.Path]::GetDirectoryName($tempDir),$tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($tempDir) -match '^rb-\d+$' -and [IO.Path]::GetFileName($tempBat) -eq 'setup.bat') { try { Remove-Item -LiteralPath $tempBat -Force -ErrorAction Stop; [IO.Directory]::Delete($tempDir) } catch { [System.Windows.MessageBox]::Show('Не удалось удалить временный BAT-файл.', 'Russian Banks') | Out-Null } } }"
exit /b
# POWERSHELL BELOW
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$ErrorActionPreference = 'Stop'
$profileName = 'Russian Banks'
$script:firefox = $null
$script:work = $null
$script:process = $null
$script:phase = 'idle'
$script:downloadIndex = 0
$script:createdProfile = $null
$script:existingProfile = $false
$script:beforeProfiles = @()
$script:snapshotReady = $false
$script:profileCreationStarted = $false
$script:files = @(
    'Russian_Trusted_Root_CA.cer',
    'Russian_Trusted_Sub_CA.cer',
    'Russian_Trusted_Sub_CA_2024.cer'
)
$script:expectedHashes = @{
    'Russian_Trusted_Root_CA.cer' = '936A43FEA6E8E525BCC0F81ACD9C3D21B4FC4B9B68ACEA7906D698005AFC6504'
    'Russian_Trusted_Sub_CA.cer' = 'F0AE589F36774F29EF3648F7984B08D42FCCE6F1FFEEB6236D773DAEB2744EA6'
    'Russian_Trusted_Sub_CA_2024.cer' = '6F9D829C8E6712444FCE3624658D8788672849C5D5B7B53FD9CF7E83EAC4193E'
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
public static class FirefoxProfileDb {
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nBytes, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_column_bytes(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
    static extern int sqlite3_close(IntPtr db);
    static byte[] Utf8(string text) { return Encoding.UTF8.GetBytes(text + "\0"); }
    static string Column(IntPtr statement, int index) {
        IntPtr pointer = sqlite3_column_text(statement, index);
        if (pointer == IntPtr.Zero) return "";
        int count = 0;
        while (Marshal.ReadByte(pointer, count) != 0) count++;
        byte[] bytes = new byte[count];
        Marshal.Copy(pointer, bytes, 0, count);
        return Encoding.UTF8.GetString(bytes);
    }
    public static string[] Read(string filename) {
        IntPtr db = IntPtr.Zero, statement = IntPtr.Zero;
        var rows = new List<string>();
        int code = sqlite3_open_v2(Utf8(filename), out db, 1, IntPtr.Zero);
        if (code != 0) throw new Exception("Не удалось открыть базу профилей Firefox: " + code);
        try {
            string query = "SELECT name, path FROM Profiles";
            code = sqlite3_prepare_v2(db, Utf8(query), -1, out statement, IntPtr.Zero);
            if (code != 0) throw new Exception("Не удалось прочитать базу профилей Firefox: " + code);
            while ((code = sqlite3_step(statement)) == 100) {
                rows.Add(Column(statement, 0) + "\t" + Column(statement, 1));
            }
            if (code != 101) throw new Exception("Ошибка чтения базы профилей Firefox: " + code);
            return rows.ToArray();
        } finally {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            sqlite3_close(db);
        }
    }
    static bool TrustEquals(IntPtr statement, int column, byte expected) {
        if (sqlite3_column_bytes(statement, column) != 4) return false;
        IntPtr value = sqlite3_column_blob(statement, column);
        return value != IntPtr.Zero && Marshal.ReadByte(value, 0) == 0 &&
            Marshal.ReadByte(value, 1) == 0 && Marshal.ReadByte(value, 2) == 0 &&
            Marshal.ReadByte(value, 3) == expected;
    }
    public static bool ContainsCertificate(string filename, byte[] der, bool root) {
        IntPtr db = IntPtr.Zero, statement = IntPtr.Zero;
        int code = sqlite3_open_v2(Utf8(filename), out db, 1, IntPtr.Zero);
        if (code != 0) throw new Exception("Не удалось открыть cert9.db: " + code);
        try {
            bool found = false;
            code = sqlite3_prepare_v2(db, Utf8("SELECT a11 FROM nssPublic WHERE a11 IS NOT NULL"), -1, out statement, IntPtr.Zero);
            if (code != 0) throw new Exception("Не удалось прочитать cert9.db: " + code);
            while ((code = sqlite3_step(statement)) == 100) {
                if (sqlite3_column_bytes(statement, 0) != der.Length) continue;
                IntPtr pointer = sqlite3_column_blob(statement, 0);
                byte[] candidate = new byte[der.Length];
                Marshal.Copy(pointer, candidate, 0, candidate.Length);
                bool equal = true;
                for (int i = 0; i < der.Length; i++) if (der[i] != candidate[i]) { equal = false; break; }
                if (equal) { found = true; break; }
            }
            if (!found && code != 101) throw new Exception("Ошибка чтения cert9.db: " + code);
            if (!found) return false;
            sqlite3_finalize(statement);
            statement = IntPtr.Zero;
            byte[] hash;
            using (var sha = SHA256.Create()) hash = sha.ComputeHash(der);
            string hex = BitConverter.ToString(hash).Replace("-", "");
            string query = "SELECT a62c, a62f FROM nssPublic WHERE a0=x'0000000b' AND a635=x'" + hex + "'";
            code = sqlite3_prepare_v2(db, Utf8(query), -1, out statement, IntPtr.Zero);
            if (code != 0) throw new Exception("Не удалось прочитать доверие сертификата: " + code);
            while ((code = sqlite3_step(statement)) == 100) {
                if (TrustEquals(statement, 0, root ? (byte)2 : (byte)4) && TrustEquals(statement, 1, 4)) return true;
            }
            if (code != 101) throw new Exception("Ошибка чтения доверия сертификата: " + code);
            return false;
        } finally {
            if (statement != IntPtr.Zero) sqlite3_finalize(statement);
            sqlite3_close(db);
        }
    }
}
'@

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Russian Banks" Width="920" Height="740" MinWidth="920" MinHeight="740"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        ResizeMode="NoResize" Background="Transparent" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#6675FF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="box" Background="{TemplateBinding Background}" CornerRadius="11" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="Background" Value="#7B87FF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="box" Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="#26304B"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="#A83447"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="box" Background="{TemplateBinding Background}" CornerRadius="11" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="Background" Value="#C44459"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="box" Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CopyLinkButton" TargetType="Button">
      <Setter Property="Background" Value="#213B58"/>
      <Setter Property="Foreground" Value="#91D9FF"/>
      <Setter Property="BorderBrush" Value="#4779A5"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="linkBox" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="linkBox" Property="Background" Value="#315E80"/>
                <Setter TargetName="linkBox" Property="BorderBrush" Value="#85D9FF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="linkBox" Property="Background" Value="#477FA2"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="18" CornerRadius="22" Background="#121A2D" BorderBrush="#354361" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="8" Opacity="0.5" Color="#000000"/></Border.Effect>
    <Grid Margin="34,27,34,28">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid Grid.Row="0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="34" Height="34" Background="#6675FF" CornerRadius="10" Margin="0,0,12,0">
            <TextBlock Text="RB" FontSize="13" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="RUSSIAN BANKS" Foreground="#CBD5F5" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
        </StackPanel>
        <Button x:Name="ProfileButton" Grid.Column="1" Content="Открыть менеджер профилей" Style="{StaticResource SecondaryButton}"
                FontSize="12" Padding="12,8" Margin="0,0,12,0" ToolTip="Открыть about:profilemanager в Firefox"/>
        <Button x:Name="CloseButton" Grid.Column="2" Content="×" Width="34" Height="34" FontSize="23"
                Foreground="#9DA9C8" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
      </Grid>
      <StackPanel Grid.Row="1" VerticalAlignment="Center">
        <TextBlock x:Name="StepText" Text="ПОДГОТОВКА" Foreground="#8796C5" FontSize="12" FontWeight="Bold" Margin="0,0,0,15"/>
        <TextBlock x:Name="Heading" Text="Отдельный Firefox для банков" Foreground="White" FontSize="31" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,14"/>
        <TextBlock x:Name="Description" Text="Найдем Russian Banks или поможем создать его. Для готового профиля включим отдельный значок на панели задач."
                   Foreground="#B9C5E0" FontSize="16" LineHeight="25" TextWrapping="Wrap" Margin="0,0,0,23"/>
        <Button x:Name="SettingsLink" Content="Открыть настройки сертификатов"
                Style="{StaticResource CopyLinkButton}" HorizontalAlignment="Left" Margin="0,0,0,20"
                Visibility="Collapsed" ToolTip="Открыть настройки в профиле Russian Banks"/>
        <Button x:Name="CopyNameButton" Content="Russian Banks  ·  Скопировать название"
                Style="{StaticResource CopyLinkButton}" HorizontalAlignment="Left" Margin="0,0,0,20"
                Visibility="Collapsed" ToolTip="Нажмите, чтобы скопировать имя нового профиля"/>
        <Border Background="#1C2740" CornerRadius="12" Padding="18,15">
          <TextBlock x:Name="Detail" Text="Существующие профили и хранилище сертификатов Windows не затрагиваются."
                     Foreground="#D7DFFC" FontSize="14" LineHeight="21" TextWrapping="Wrap"/>
        </Border>
        <StackPanel x:Name="ImportGuide" Visibility="Collapsed" Margin="0,18,0,0">
          <Border Background="#20304A" CornerRadius="11" Padding="15,10" Margin="0,0,0,8">
            <StackPanel>
              <TextBlock Text="1   КОРНЕВОЙ  ·  Russian_Trusted_Root_CA.cer" Foreground="White" FontSize="14" FontWeight="SemiBold"/>
              <TextBlock Text="Сайты / Websites: поставить галочку     Почта / Email: не ставить" Foreground="#BFD3FF" FontSize="13" Margin="24,5,0,0"/>
            </StackPanel>
          </Border>
          <Border Background="#20304A" CornerRadius="11" Padding="15,10" Margin="0,0,0,8">
            <StackPanel>
              <TextBlock Text="2   ПРОМЕЖУТОЧНЫЙ  ·  Russian_Trusted_Sub_CA.cer" Foreground="White" FontSize="14" FontWeight="SemiBold"/>
              <TextBlock Text="Не ставить галочки / Leave both unchecked" Foreground="#BFD3FF" FontSize="13" Margin="24,5,0,0"/>
            </StackPanel>
          </Border>
          <Border Background="#20304A" CornerRadius="11" Padding="15,10">
            <StackPanel>
              <TextBlock Text="3   ПРОМЕЖУТОЧНЫЙ 2024  ·  Russian_Trusted_Sub_CA_2024.cer" Foreground="White" FontSize="14" FontWeight="SemiBold"/>
              <TextBlock Text="Не ставить галочки / Leave both unchecked" Foreground="#BFD3FF" FontSize="13" Margin="24,5,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </StackPanel>
      <Grid Grid.Row="2">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="Footer" Text="Шаг 0 из 4" Foreground="#7F8EAF" FontSize="13" VerticalAlignment="Center"/>
        <Button x:Name="CancelButton" Grid.Column="1" Content="Отменить настройку" Style="{StaticResource DangerButton}"
                Visibility="Collapsed" Margin="0,0,10,0"/>
        <Button x:Name="FolderButton" Grid.Column="2" Content="Открыть папку" Style="{StaticResource SecondaryButton}"
                Visibility="Collapsed" Margin="0,0,10,0"/>
        <Button x:Name="ActionButton" Grid.Column="3" Content="Начать настройку" Style="{StaticResource PrimaryButton}" MinWidth="180"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($name in @('ProfileButton','CloseButton','StepText','Heading','Description','SettingsLink','CopyNameButton','Detail','ImportGuide','Footer','CancelButton','FolderButton','ActionButton')) {
    Set-Variable -Name $name -Value $window.FindName($name)
}

function Set-Screen([string]$newStep, [string]$newHeading, [string]$newDescription, [string]$newDetail, [string]$newFooter) {
    $StepText.Text = $newStep
    $Heading.Text = $newHeading
    $Description.Text = $newDescription
    $Detail.Text = $newDetail
    $Footer.Text = $newFooter
}

function Get-SelectableProfiles {
    $groupFolder = Join-Path $env:APPDATA 'Mozilla\Firefox\Profile Groups'
    if (-not (Test-Path -LiteralPath $groupFolder)) { return @() }
    $result = @()
    foreach ($db in Get-ChildItem -LiteralPath $groupFolder -Filter '*.sqlite' -File) {
        foreach ($row in [FirefoxProfileDb]::Read($db.FullName)) {
            $fields = $row.Split(@([char]9), 2)
            if ($fields.Count -ne 2) { continue }
            $result += [pscustomobject]@{ Name = $fields[0]; Path = $fields[1]; Database = $db.FullName }
        }
    }
    return $result
}

function Get-CreatedProfile([bool]$includeExisting = $false) {
    $matches = @(Get-SelectableProfiles | Where-Object {
        $_.Name -eq $profileName -and ($includeExisting -or $script:beforeProfiles -notcontains ($_.Database + '|' + $_.Path))
    })
    if ($matches.Count -gt 1) { throw 'Найдено несколько новых профилей Russian Banks. Удалите лишние через менеджер Firefox.' }
    if ($matches.Count -eq 0) { return $null }
    $path = $matches[0].Path.Replace('/', '\')
    if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Join-Path $env:APPDATA 'Mozilla\Firefox') $path }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Firefox зарегистрировал профиль, но его папка не найдена.' }
    $matches[0] | Add-Member -NotePropertyName FullPath -NotePropertyValue $path -Force
    return $matches[0]
}

function Set-ProfileTaskbarPreference {
    if (-not $script:createdProfile -or $script:createdProfile.Name -ne $profileName) { throw 'Нужный профиль Firefox не определен.' }
    $root = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles')).TrimEnd('\') + '\'
    $folder = [IO.Path]::GetFullPath($script:createdProfile.FullPath).TrimEnd('\') + '\'
    if (-not $folder.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Профиль находится вне каталога Firefox.' }
    $userJs = Join-Path $folder 'user.js'
    $setting = 'user_pref("taskbar.grouping.useprofile", true);'
    if (Test-Path -LiteralPath $userJs) {
        $contents = [IO.File]::ReadAllText($userJs, [Text.Encoding]::UTF8)
        $assignments = [regex]::Matches($contents, '(?m)^[ \t]*user_pref\("taskbar\.grouping\.useprofile",[ \t]*(true|false)\);[ \t]*$')
        if ($assignments.Count -gt 0 -and $assignments[$assignments.Count - 1].Groups[1].Value -eq 'true') { return }
        $separator = if ($contents -and -not $contents.EndsWith("`n")) { "`r`n" } else { '' }
        [IO.File]::AppendAllText($userJs, $separator + $setting + "`r`n", [Text.UTF8Encoding]::new($false))
    } else {
        [IO.File]::WriteAllText($userJs, $setting + "`r`n", [Text.UTF8Encoding]::new($false))
    }
}

function Get-NewProfiles {
    if (-not $script:snapshotReady -or -not $script:profileCreationStarted) { return @() }
    return @(Get-SelectableProfiles | Where-Object {
        $_.Name -eq $profileName -and $script:beforeProfiles -notcontains ($_.Database + '|' + $_.Path)
    })
}

function Clear-TemporaryFiles {
    if (-not $script:work -or -not (Test-Path -LiteralPath $script:work)) { return }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($script:work)
    if (-not $target.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($target) -like 'RussianBanks_*')) {
        throw 'Отказано в удалении: папка находится вне временного каталога.'
    }
    $folder = Get-Item -LiteralPath $target -Force
    if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Отказано в удалении: временная папка является ссылкой.' }
    foreach ($name in $script:files) {
        $path = Join-Path $target $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Отказано в удалении: $name не является обычным файлом." }
        [IO.File]::Delete($path)
    }
    if (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) {
        [IO.Directory]::Delete($target)
    } else {
        [System.Windows.MessageBox]::Show("Загруженные сертификаты удалены. Временная папка содержит другие файлы и сохранена: $target", 'Очистка') | Out-Null
    }
    $script:work = $null
}

function Get-MissingCertificates {
    if (-not $script:createdProfile) { throw 'Новый профиль не определен.' }
    $certDb = Join-Path $script:createdProfile.FullPath 'cert9.db'
    $keyDb = Join-Path $script:createdProfile.FullPath 'key4.db'
    if (-not (Test-Path -LiteralPath $certDb) -or -not (Test-Path -LiteralPath $keyDb)) {
        return @($script:files)
    }
    $missing = @()
    foreach ($file in $script:files) {
        $source = Join-Path $script:work $file
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($source)
        if (-not [FirefoxProfileDb]::ContainsCertificate($certDb, $cert.RawData, ($file -eq $script:files[0]))) { $missing += $file }
    }
    return $missing
}

function Stop-Setup([string]$message) {
    $script:phase = 'error'
    if ($timer) { $timer.Stop() }
    if ($script:process) {
        try {
            if (-not $script:process.HasExited) {
                $script:process.Kill()
                $null = $script:process.WaitForExit(5000)
            }
        } catch {} finally {
            $script:process.Dispose()
            $script:process = $null
        }
    }
    Set-Screen 'ОШИБКА' 'Настройка остановлена' $message 'Исправьте причину и запустите файл снова. Существующие профили Firefox не изменяются этим файлом.' 'Требуется действие'
    $ActionButton.Content = 'Отменить и очистить'
    $ActionButton.IsEnabled = $true
    $CancelButton.Visibility = 'Visible'
}

function Open-NewProfileManager {
    if (-not $script:firefox) {
        foreach ($candidate in @(
            (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
        )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { $script:firefox = $candidate; break }
        }
    }
    if (-not $script:firefox) { throw 'Firefox не найден в Program Files или Program Files (x86).' }
    Start-Process -FilePath $script:firefox -ArgumentList 'about:profilemanager'
}

function Open-CertificateSettings {
    if (-not $script:createdProfile -or -not (Test-Path -LiteralPath $script:createdProfile.FullPath -PathType Container)) {
        throw 'Папка нового профиля Russian Banks не найдена.'
    }
    $arguments = '-profile "' + $script:createdProfile.FullPath + '" "about:preferences#connectionSecurity"'
    Start-Process -FilePath $script:firefox -ArgumentList $arguments
}

function Start-Child([string]$file, [string]$arguments, [string]$phase) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $file
    $info.Arguments = $arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $script:process = [System.Diagnostics.Process]::Start($info)
    if (-not $script:process) { throw "Не удалось запустить $file" }
    $script:phase = $phase
    $timer.Start()
}

function Start-Download {
    if ($script:downloadIndex -ge $script:files.Count) {
        if ($script:existingProfile -and @(Get-MissingCertificates).Count -eq 0) {
            Clear-TemporaryFiles
            $script:phase = 'done'
            Set-Screen 'ГОТОВО' 'Russian Banks уже настроен' 'Все три сертификата и доверие для сайтов проверены в этом профиле.' 'Если профиль открыт, закройте и снова откройте его для применения настройки панели задач.' 'Завершено'
            $ActionButton.Content = 'Закрыть'
            $ActionButton.IsEnabled = $true
            $CancelButton.Visibility = 'Collapsed'
            return
        }
        Show-ImportStep
        return
    }
    $file = $script:files[$script:downloadIndex]
    Set-Screen 'ЗАГРУЗКА СЕРТИФИКАТОВ' 'Получаем файлы Минцифры' "Загружается файл $($script:downloadIndex + 1) из 3." $file "Шаг 2 из 4"
    $url = 'https://gu-st.ru/content/downloads/' + $file
    $destination = Join-Path $script:work $file
    Start-Child 'curl.exe' ('-fL --retry 2 --connect-timeout 20 --max-time 120 "' + $url + '" -o "' + $destination + '"') 'download'
}

function Show-ImportStep {
    try {
        Open-CertificateSettings
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:work + '"')
    } catch {
        Stop-Setup "Не удалось открыть настройки Firefox или Проводник: $($_.Exception.Message)"
        return
    }
    $script:phase = 'import'
    Set-Screen 'ИМПОРТ · 3 ФАЙЛА' 'Добавьте сертификаты в Firefox' 'Настройки открыты в Russian Banks. В Firefox нажмите «Управление сертификатами» / “Manage certificates” → «Центры сертификации» / “Authorities” → «Импортировать» / “Import”.' 'Если сертификат уже есть, настройте его через «Изменить доверие» / Edit Trust.' 'Шаг 3 из 4'
    $SettingsLink.Content = 'Открыть настройки сертификатов'
    $SettingsLink.Visibility = 'Visible'
    $ImportGuide.Visibility = 'Visible'
    $FolderButton.Visibility = 'Visible'
    $ActionButton.Content = 'Проверить сертификаты'
    $ActionButton.IsEnabled = $true
    $script:frontTimer.Start()
}

$script:frontTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:frontTimer.Interval = [TimeSpan]::FromMilliseconds(2200)
$script:frontTimer.Add_Tick({
    $script:frontTimer.Stop()
    $window.Topmost = $true
    $null = $window.Activate()
    $window.Topmost = $false
    $null = $window.Focus()
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    if ($script:phase -ne 'download' -or -not $script:process -or -not $script:process.HasExited) { return }
    $timer.Stop()
    $exitCode = $script:process.ExitCode
    $script:process.Dispose()
    $script:process = $null
    try {
        if ($exitCode -ne 0) { throw "Команда завершилась с кодом $exitCode." }
        if ($script:phase -eq 'download') {
            $file = Join-Path $script:work $script:files[$script:downloadIndex]
            if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw 'Загруженный файл пуст или отсутствует.' }
            $null = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($file)
            $name = $script:files[$script:downloadIndex]
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $script:expectedHashes[$name]) { throw "Отпечаток сертификата $name не совпадает с проверенным. Импорт остановлен." }
            $script:downloadIndex++
            Start-Download
        }
    } catch {
        Stop-Setup $_.Exception.Message
    }
})

$CloseButton.Add_Click({
    if ($script:phase -in @('new-profile','download','import','cancel-delete','error')) {
        [System.Windows.MessageBox]::Show('Используйте кнопку «Отменить настройку», чтобы удалить временные файлы и завершить отмену профиля.', 'Настройка не завершена') | Out-Null
        return
    }
    $window.Close()
})
$window.Add_Closing({
    if ($script:phase -in @('new-profile','download','import','cancel-delete','error')) {
        $_.Cancel = $true
        [System.Windows.MessageBox]::Show('Сначала завершите или отмените настройку в этом окне.', 'Настройка не завершена') | Out-Null
    }
})
$SettingsLink.Add_Click({
    try {
        Open-CertificateSettings
    } catch {
        [System.Windows.MessageBox]::Show("Не удалось открыть настройки: $($_.Exception.Message)", 'Настройки Firefox') | Out-Null
    }
})
$ProfileButton.Add_Click({
    try {
        Open-NewProfileManager
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Профили Firefox') | Out-Null
    }
})
$CopyNameButton.Add_Click({
    try {
        [System.Windows.Clipboard]::SetText($profileName)
        $CopyNameButton.Content = 'Название скопировано ✓'
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Буфер обмена') | Out-Null
    }
})
$CopyNameButton.Add_MouseLeave({ $CopyNameButton.Content = 'Russian Banks  ·  Скопировать название' })
$window.Add_MouseLeftButtonDown({
    if ($_.OriginalSource -isnot [System.Windows.Controls.Button]) {
        try { $window.DragMove() } catch {}
    }
})
$FolderButton.Add_Click({
    if ($script:work -and (Test-Path -LiteralPath $script:work)) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:work + '"')
    }
})
$CancelButton.Add_Click({
    try {
        $script:phase = 'cancelling'
        $timer.Stop()
        if ($script:process) {
            if (-not $script:process.HasExited) {
                $script:process.Kill()
                if (-not $script:process.WaitForExit(5000)) { throw 'Загрузка еще не остановилась. Повторите отмену через несколько секунд.' }
            }
            $script:process.Dispose()
            $script:process = $null
        }
        Clear-TemporaryFiles
        $SettingsLink.Visibility = 'Collapsed'
        $CopyNameButton.Visibility = 'Collapsed'
        $FolderButton.Visibility = 'Collapsed'
        $ImportGuide.Visibility = 'Collapsed'
        $newProfiles = @(Get-NewProfiles)
        if ($newProfiles.Count -gt 1) {
            $script:phase = 'cancelled'
            Set-Screen 'ОТМЕНЕНО' 'Проверьте профили вручную' 'Временные сертификаты удалены. Найдено несколько новых профилей Russian Banks, поэтому мастер не может выбрать профиль для удаления.' 'Удалите только тот профиль, который создали для этой настройки.' 'Отменено'
            $ActionButton.Content = 'Закрыть'
            $CancelButton.Visibility = 'Collapsed'
            return
        }
        if ($newProfiles.Count -eq 1) {
            $script:createdProfile = $newProfiles[0]
            $profileToDelete = $script:createdProfile.Name
            Open-NewProfileManager
            $script:phase = 'cancel-delete'
            Set-Screen 'ОТМЕНА' 'Удалите новый профиль в Firefox' "Сертификаты из временной папки удалены. В менеджере Firefox найдите $profileToDelete, откройте редактирование и нажмите «Удалить» / “Delete”. Подтвердите удаление в Firefox." 'Старый профиль Russian Banks из классического списка не удаляйте. После удаления нажмите «Проверить удаление». Мастер проверит базу нового менеджера.' 'Отмена · профиль ожидает удаления'
            $ActionButton.Content = 'Проверить удаление'
            $ActionButton.IsEnabled = $true
        } else {
            $script:phase = 'cancelled'
            Set-Screen 'ОТМЕНЕНО' 'Настройка отменена' 'Временные файлы удалены. Новый профиль Russian Banks в базе Firefox не найден.' 'Если вы создали профиль с другим именем, удалите его через менеджер профилей Firefox.' 'Отменено'
            $ActionButton.Content = 'Закрыть'
            $ActionButton.IsEnabled = $true
            $CancelButton.Visibility = 'Collapsed'
        }
    } catch { Stop-Setup "Отмена не завершена: $($_.Exception.Message)" }
})
$ActionButton.Add_Click({
    if ($script:phase -in @('done','cancelled')) { $window.Close(); return }
    if ($script:phase -eq 'error') {
        $CancelButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        return
    }
    if ($script:phase -eq 'cancel-delete') {
        try {
            $remaining = @(Get-NewProfiles)
            if ($remaining.Count -gt 0) {
                [System.Windows.MessageBox]::Show('Новый профиль еще числится в Firefox. Удалите его в менеджере и повторите проверку.', 'Удаление профиля') | Out-Null
                return
            }
            $script:phase = 'cancelled'
            Set-Screen 'ОТМЕНЕНО' 'Профиль удален' 'Firefox больше не показывает созданный профиль в базе. Временные сертификаты удалены.' 'Существующие профили не затронуты мастером.' 'Отменено'
            $ActionButton.Content = 'Закрыть'
            $CancelButton.Visibility = 'Collapsed'
        } catch { Stop-Setup $_.Exception.Message }
        return
    }
    if ($script:phase -eq 'new-profile') {
        try {
            $script:createdProfile = Get-CreatedProfile
            if (-not $script:createdProfile) {
                [System.Windows.MessageBox]::Show('Новый профиль с именем Russian Banks не найден. Откройте «Профили» → «+ Новый профиль», задайте имя через кнопку копирования и дождитесь отдельного окна Firefox.', 'Профиль еще не создан') | Out-Null
                return
            }
            Set-ProfileTaskbarPreference
            $CopyNameButton.Visibility = 'Collapsed'
            $ActionButton.IsEnabled = $false
            $script:work = Join-Path ([IO.Path]::GetTempPath()) ('RussianBanks_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:work | Out-Null
            $script:downloadIndex = 0
            Start-Download
        } catch { Stop-Setup $_.Exception.Message }
        return
    }
    if ($script:phase -eq 'import') {
        try {
            $missing = @(Get-MissingCertificates)
            if ($missing.Count -gt 0) {
                [System.Windows.MessageBox]::Show(("Сертификаты отсутствуют или доверие выставлено неверно:`n" + ($missing -join "`n") + "`n`nИмпортируйте файлы или исправьте доверие через Изменить доверие / Edit Trust. Затем повторите проверку."), 'Импорт не завершен') | Out-Null
                return
            }
            Clear-TemporaryFiles
            $script:phase = 'done'
            $ImportGuide.Visibility = 'Collapsed'
            $SettingsLink.Visibility = 'Collapsed'
            $FolderButton.Visibility = 'Collapsed'
            Set-Screen 'ГОТОВО' 'Профиль подготовлен' 'Временная папка с загруженными сертификатами удалена.' 'Чтобы значок Russian Banks был отдельным, закройте и снова откройте этот профиль Firefox.' 'Завершено'
            $ActionButton.Content = 'Закрыть'
            $CancelButton.Visibility = 'Collapsed'
        } catch {
            Stop-Setup "Не удалось удалить временную папку: $($_.Exception.Message). Папка: $script:work"
        }
        return
    }
    if ($script:phase -ne 'idle') { return }
    $ActionButton.IsEnabled = $false
    try {
        Set-Screen 'ПРОВЕРКА' 'Ищем Firefox' 'Проверяем установленный браузер.' 'Для начала работы закройте все окна Firefox.' 'Шаг 1 из 4'
        $script:beforeProfiles = @(Get-SelectableProfiles | ForEach-Object { $_.Database + '|' + $_.Path })
        $script:snapshotReady = $true
        $script:createdProfile = Get-CreatedProfile -includeExisting $true
        if ($script:createdProfile) {
            Set-ProfileTaskbarPreference
            $script:existingProfile = $true
            $script:work = Join-Path ([IO.Path]::GetTempPath()) ('RussianBanks_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:work | Out-Null
            $script:downloadIndex = 0
            $CancelButton.Visibility = 'Visible'
            Start-Download
            return
        }
        if (Get-Process -Name 'firefox' -ErrorAction SilentlyContinue) { throw 'Firefox открыт. Закройте все его окна и запустите настройку снова.' }
        Open-NewProfileManager
        $script:profileCreationStarted = $true
        $script:phase = 'new-profile'
        Set-Screen 'ВАШ ХОД' 'Создайте новый профиль' 'Сейчас открыт основной Firefox – это нормально. В странице управления нажмите «+ Новый профиль» / “+ New profile”. Откроется отдельное окно. В нем задайте имя Russian Banks, выберите значок и нажмите «Готово» / “Done editing”.' 'Проверьте имя Russian Banks в меню «Профили» нового окна. Старый одноименный профиль из классического списка не трогайте. Кнопка ниже копирует нужное имя.' 'Шаг 1 из 4'
        $CopyNameButton.Visibility = 'Visible'
        $CancelButton.Visibility = 'Visible'
        $ActionButton.Content = 'Проверить профиль'
        $ActionButton.IsEnabled = $true
    } catch {
        Stop-Setup $_.Exception.Message
    }
})

$null = $window.ShowDialog()
