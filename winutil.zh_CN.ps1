<#
.NOTES
    Author         : Chris Titus @christitustech
    Runspace Author: @DeveloperDurp
    GitHub         : https://github.com/ChrisTitusTech
    Version        : 26.08.04
#>
<#
.中文说明
  这是 WinUtil（Chris Titus Tech）脚本的“中文注释 + 界面汉化”版本（非官方）。
  目标：
    1) 只翻译用户可见文字（界面按钮、提示、弹窗与部分日志），不改变原有功能逻辑；
    2) 给主要模块与函数补充中文注释，帮助理解各项功能。
  注意：
    - 本文件基于上游 Release 26.08.04；后续同步仍应以上游脚本为逻辑基线。
    - WinUtil 会修改系统设置、注册表、服务和更新策略；请先备份重要数据，建议先在虚拟机测试。

.模块速览（对应 WinUtil 顶部标签页）
  安装（Install）
    - 安装、升级或卸载常用软件，并可筛选软件分类
  优化（Tweaks）
    - 应用推荐预设或按单项调整隐私、性能与界面设置
    - AppX Removal 可移除或恢复所选系统应用
  配置（Config）
    - 导入或导出所选项目及执行配置
  更新（Updates）
    - 在推荐、Windows 默认和禁用更新三种策略间切换
  Win11ISO（镜像制作）
    - 验证 Windows 11 ISO、修改 install.wim，并输出 ISO 或写入 USB

#>

param (
    [string]$Config,
    [ValidateSet("Standard", "Minimal", "Advanced", "")]
    [string]$Preset,
    [switch]$Offline
)

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinUtil 无法在当前系统上运行：PowerShell 执行受到安全策略限制。" -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WinUtil 需要以管理员身份运行，正在尝试提升权限并重新启动。"
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.version = "26.08.04"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.Win11ISOProcessRunning = $false
$sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$winutildir = "$env:LocalAppData\winutil"
$sync.winutildir = $winutildir

$logdir = "$winutildir\logs"
$sync.logPath = "$logdir\winutil_$dateTime.log"
$sync.transcriptPath = $sync.logPath
Start-Transcript -Path $sync.logPath -Append -NoClobber | Out-Null

$Host.UI.RawUI.WindowTitle = "WinUtil"
Clear-Host
# [功能说明] Add-SelectedAppsMenuItem：向界面或数据结构中添加条目（例如：已选应用、菜单项、按钮事件等）。
function Add-SelectedAppsMenuItem {
    <#
    .SYNOPSIS
        This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

    .Parameter name
        The actual Name of an App like "Chrome" or "Brave"
        This name is contained in the "Content" property inside the applications.json
    .PARAMETER key
        The key which identifies an app object in applications.json
        For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
    #>

    param ([string]$name, [string]$key)

    $selectedAppGrid = New-Object Windows.Controls.Grid

    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

    # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
    # With the tooltip, you can still read the whole entry on hover
    $selectedAppLabel = New-Object Windows.Controls.Label
    $selectedAppLabel.Content = $name
    $selectedAppLabel.ToolTip = $name
    $selectedAppLabel.HorizontalAlignment = "Left"
    $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
    $selectedAppGrid.Children.Add($selectedAppLabel)

    $selectedAppRemoveButton = New-Object Windows.Controls.Button
    $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
    $selectedAppRemoveButton.Content = [string]([char]0xE711)
    $selectedAppRemoveButton.HorizontalAlignment = "Center"
    $selectedAppRemoveButton.Tag = $key
    $selectedAppRemoveButton.ToolTip = "从选择中移除此应用"
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

    # Highlight the Remove icon on Hover
    $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
    $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
    $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
    })
    [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
    $selectedAppGrid.Children.Add($selectedAppRemoveButton)
    # Add new Element to Popup
    $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
}

# [功能说明] Close-WinUtilRunspacePool：关闭后台运行空间并释放相关资源。

function Close-WinUtilRunspacePool {
    if ($null -eq $sync -or -not $sync.ContainsKey("runspace") -or $null -eq $sync.runspace) {
        return
    }

    try {
        if ($sync.runspace.RunspacePoolStateInfo.State -notin @(
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closed,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closing,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Broken
        )) {
            $sync.runspace.Close()
        }
    } finally {
        $sync.runspace.Dispose()
        $sync.Remove("runspace")
    }
}

# [功能说明] Find-AppsByNameOrDescription：脚本内部函数（用于组织代码与复用逻辑）。

function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .DESCRIPTION
            Filters application entries by name or description using literal string matching.
            Respects collapsed category state and handles null $sync gracefully.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .PARAMETER Category
            When provided, only applications in this exact category are shown.

        .NOTES
            - Uses module-scope $sync (no parameter needed; inherits from caller's scope)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing hashtable keys and null UI elements
            - Protected by try/catch to prevent UI thread crashes
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = "",

        [Parameter(Mandatory = $false)]
        [string]$Category = ""
    )

    # Validate that $sync exists and has required structure
    if ($null -eq $sync) {
        Write-Warning "Find-AppsByNameOrDescription: Global `$sync not found. Aborting search."
        return
    }

    if ($null -eq $sync.ItemsControl) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.ItemsControl not initialized. Aborting search."
        return
    }

    if ($null -eq $sync.configs -or $null -eq $sync.configs.applicationsHashtable) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.configs.applicationsHashtable not initialized. Aborting search."
        return
    }

    try {
        # Reset the visibility if the search string is empty or the search is cleared
        if ([string]::IsNullOrWhiteSpace($SearchString) -and [string]::IsNullOrWhiteSpace($Category)) {
            $sync.ItemsControl.Items | ForEach-Object {
                # Each item is a StackPanel container
                $_.Visibility = [Windows.Visibility]::Visible

                if ($_.Children.Count -ge 2) {
                    $categoryLabel = $_.Children[0]
                    $wrapPanel = $_.Children[1]

                    # Keep category label visible
                    $categoryLabel.Visibility = [Windows.Visibility]::Visible

                    # Respect the collapsed state of categories (indicated by + prefix)
                    if ($categoryLabel.Content -like "+*") {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                    }
                    else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    }

                    # Show all apps within the category
                    $wrapPanel.Children | ForEach-Object {
                        $_.Visibility = [Windows.Visibility]::Visible
                    }
                }
            }
            return
        }

        # Escape wildcard characters for literal matching
        $escapedSearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

        # Perform search
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]
                $categoryHasMatch = $false

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # Search through apps in this category
                foreach ($appControl in $wrapPanel.Children) {
                    # Safely retrieve app entry from hashtable
                    $appTag = $appControl.Tag
                    $appEntry = $null

                    if (-not [string]::IsNullOrWhiteSpace($appTag) -and $sync.configs.applicationsHashtable.ContainsKey($appTag)) {
                        $appEntry = $sync.configs.applicationsHashtable[$appTag]
                    }

                    # Check if app matches search criteria
                    if ($null -ne $appEntry) {
                        $categoryMatch = -not [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Category -eq $Category
                        $contentMatch = [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Content -like "*$escapedSearchString*"
                        $descriptionMatch = [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Description -like "*$escapedSearchString*"

                        if ($categoryMatch -or $contentMatch -or $descriptionMatch) {
                            # Show the App and mark that this category has a match
                            $appControl.Visibility = [Windows.Visibility]::Visible
                            $categoryHasMatch = $true
                        }
                        else {
                            $appControl.Visibility = [Windows.Visibility]::Collapsed
                        }
                    }
                    else {
                        # Hide app if no entry found (data integrity issue)
                        $appControl.Visibility = [Windows.Visibility]::Collapsed
                    }
                }

                # If category has matches, show the WrapPanel and update the category label to expanded state
                if ($categoryHasMatch) {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    $_.Visibility = [Windows.Visibility]::Visible
                    # Update category label to show expanded state (-)
                    if ($categoryLabel.Content -like "+*") {
                        $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                    }
                }
                else {
                    # Hide the entire category container if no matches
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        Write-Warning "Find-AppsByNameOrDescription: An error occurred during search: $_"
        # Fail gracefully - do not crash the UI thread
        return
    }
}

# [功能说明] Find-TweaksByNameOrDescription：脚本内部函数（用于组织代码与复用逻辑）。

function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .DESCRIPTION
            Filters tweak entries by name or description using literal string matching (no wildcard expansion).
            Respects collapsed category state and handles null $sync gracefully.
            Safe for rapid keystroke events; no terminal spam on error conditions.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .NOTES
            - Uses module-scope $sync (resolved via global/script fallback if needed)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing UI elements and null properties
            - Protected by try/catch to prevent UI thread crashes
            - PowerShell 5.1 compatible (no ternary operators, no advanced language features)
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = ""
    )

    # ------------------------------------------------------------------------------
    # 1. RESOLVE $SYNC WITH MULTI-LEVEL FALLBACK
    # ------------------------------------------------------------------------------

    if ($null -eq $Sync) {
        $Sync = $global:sync
        if ($null -eq $Sync) {
            $Sync = $script:sync
        }
    }

    # Validate that $Sync exists and has required structure
    if ($null -eq $Sync) {
        # Silent return - function called on every keystroke; no warning spam
        return
    }

    if ($null -eq $Sync.Form) {
        # Silent return - form not yet initialized
        return
    }

    # ------------------------------------------------------------------------------
    # 2. GET REFERENCE TO TWEAKS OR APPX PANEL
    # ------------------------------------------------------------------------------

    $panelName = "tweakspanel"
    if ($null -ne $Sync.currentTab -and $Sync.currentTab -eq "AppX") {
        $panelName = "appxpanel"
    }

    $tweaksPanel = $null
    try {
        $tweaksPanel = $Sync.Form.FindName($panelName)
    }
    catch {
        # Silent return - panel not found or disposed
        return
    }

    if ($null -eq $tweaksPanel) {
        # Silent return - panel doesn't exist
        return
    }

    # ------------------------------------------------------------------------------
    # 3. HANDLE EMPTY/WHITESPACE SEARCH STRING - RESET TO DEFAULT STATE
    # ------------------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        try {
            $tweaksPanel.Children | ForEach-Object {
                $categoryBorder = $_

                # Safely set visibility
                if ($null -ne $categoryBorder) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }

                # Process each category
                if ($categoryBorder -is [Windows.Controls.Border]) {
                    $dockPanel = $null
                    if ($null -ne $categoryBorder.Child) {
                        $dockPanel = $categoryBorder.Child
                    }

                    if ($dockPanel -is [Windows.Controls.DockPanel]) {
                        $itemsControl = $null
                        $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                        if ($null -ne $itemsControl) {
                            # Show all items in the category
                            foreach ($item in $itemsControl.Items) {
                                if ($null -ne $item) {
                                    # Check if it's a category label (first Label in the ItemsControl)
                                    if ($item -is [Windows.Controls.Label]) {
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                    elseif ($item -is [Windows.Controls.DockPanel] -or $item -is [Windows.Controls.StackPanel]) {
                                        # Show all checkbox containers
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            # Silent catch - UI element may be disposed
            $null = $_
        }

        return
    }

    # ------------------------------------------------------------------------------
    # 4. PERFORM LITERAL SEARCH (NO WILDCARD EXPANSION)
    # ------------------------------------------------------------------------------

    try {
        # Normalize search term once for the entire operation
        $searchTerm = $SearchString
        if ($null -eq $searchTerm) {
            $searchTerm = ""
        }

        # Iterate through all categories
        $tweaksPanel.Children | ForEach-Object {
            $categoryBorder = $_
            $categoryHasMatch = $false

            if ($categoryBorder -is [Windows.Controls.Border]) {
                $dockPanel = $null
                if ($null -ne $categoryBorder.Child) {
                    $dockPanel = $categoryBorder.Child
                }

                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $null
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                    if ($null -ne $itemsControl) {
                        $categoryLabel = $null

                        # Process all items (checkboxes, labels, panels) in the ItemsControl
                        for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                            $item = $itemsControl.Items[$i]

                            if ($null -eq $item) {
                                continue
                            }

                            # ------------------------------------------------------------
                            # Check if this is a category label (usually first Label)
                            # ------------------------------------------------------------

                            if ($item -is [Windows.Controls.Label]) {
                                $categoryLabel = $item
                                # Initially hide category label; show it only if matches found
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # ------------------------------------------------------------
                            # Check if this is a DockPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.DockPanel]) {
                                $checkbox = $null
                                $label = $null

                                # Safely extract checkbox and label
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                                $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                                # Check if tweak matches search criteria
                                $itemMatches = $false

                                if ($null -ne $label) {
                                    $labelContent = $label.Content
                                    $labelToolTip = $label.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $labelContent) {
                                        $labelContent = ""
                                    }
                                    if ($null -eq $labelToolTip) {
                                        $labelToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $labelContentStr = [string]$labelContent
                                    $labelToolTipStr = [string]$labelToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $labelContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $labelToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }

                            # ------------------------------------------------------------
                            # Check if this is a StackPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.StackPanel]) {
                                $checkbox = $null
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                                $itemMatches = $false

                                if ($null -ne $checkbox) {
                                    $checkboxContent = $checkbox.Content
                                    $checkboxToolTip = $checkbox.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $checkboxContent) {
                                        $checkboxContent = ""
                                    }
                                    if ($null -eq $checkboxToolTip) {
                                        $checkboxToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $checkboxContentStr = [string]$checkboxContent
                                    $checkboxToolTipStr = [string]$checkboxToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $checkboxContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $checkboxToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }
                        }

                        # ------------------------------------------------------------
                        # Update category label visibility and expanded/collapsed state
                        # ------------------------------------------------------------

                        if ($categoryHasMatch) {
                            # Show category label
                            if ($null -ne $categoryLabel) {
                                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                                # Update category label to expanded state (change "+" to "-")
                                $labelContent = $categoryLabel.Content
                                if ($null -ne $labelContent) {
                                    $labelStr = [string]$labelContent

                                    # Safe string replacement without -replace regex
                                    if ($labelStr.StartsWith("+ ")) {
                                        $expandedLabel = "- " + $labelStr.Substring(2)
                                        $categoryLabel.Content = $expandedLabel
                                    }
                                }
                            }
                        }
                    }
                }

                # ----------------------------------------------------------------
                # Set category border visibility based on whether it has matches
                # ----------------------------------------------------------------

                if ($categoryHasMatch) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }
                else {
                    $categoryBorder.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        # Silent catch - UI elements may be disposed or in unexpected state
        # Do not log to terminal as this function is called on every keystroke
        $null = $_
    }
}

# [功能说明] Get-WinUtilInstalledAPPX：读取当前系统已安装的 AppX 软件包。

function Get-WinUtilInstalledAPPX {
    <#

    .SYNOPSIS
        Gets the names of AppX packages installed for all users

    #>

    # AppX module auto-loading can leave PowerShell 7 dependent on a temporary Windows PowerShell
    # compatibility proxy. Run the query in Windows PowerShell 5.1 so it remains available after
    # those temporary proxy files are removed.
    $ps5Command = {
        Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name
    }

    $packageOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($packageOutput | Out-String).Trim()
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to get installed AppX packages: $failureDetails"
        return @()
    }

    return @($packageOutput)
}

function Get-WinUtilPackageLogSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$Preference
    )

    @($Packages | ForEach-Object {
        $package = $_
        $packageName = @($package.Name, $package.Description, $package.winget, $package.choco) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -ne "na" } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace([string]$packageName)) {
            $packageName = "Unknown package"
        }

        if ($Preference -eq "Choco" -and -not [string]::IsNullOrWhiteSpace([string]$package.choco) -and $package.choco -ne "na") {
            "$packageName (choco: $($package.choco))"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$package.winget) -and $package.winget -ne "na") {
            "$packageName (winget: $($package.winget))"
        } else {
            "$packageName (no package id)"
        }
    })
}

function Get-WinUtilSelectedPackages {

     param(
         [Parameter(Mandatory = $true)]
         [object] $PackageList,

         [Parameter(Mandatory = $true)]
         [string] $Preference
     )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages = @{
        Winget = $packagesWinget
        Choco = $packagesChoco
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId
        )

        if ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na") {
            return
        }

        if (-not $Target.Contains($PackageId)) {
            $null = $Target.Add($PackageId)
        }
    }

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget
                } else {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco
                }
            }
            "Winget" {
                Add-PackageId -Target $packagesWinget -PackageId $package.winget
            }
        }
    }

    return $packages
}

# [功能说明] Get-WinUtilToggleStatus：获取信息或资源（如：ISO/语言/依赖工具路径、系统状态等）。

Function Get-WinUtilToggleStatus ($ToggleSwitch) {

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    if ($null -eq $sync.ToggleStatusCache) {
        $sync.ToggleStatusCache = @{}
    }

    if ($sync.ToggleStatusCache.ContainsKey($ToggleSwitch)) {
        return [bool]$sync.ToggleStatusCache[$ToggleSwitch]
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
    }

    foreach ($regentry in $ToggleSwitchReg) {

        if (Test-Path $regentry.Path) {
            $regstate = (Get-ItemProperty -Path $regentry.Path).$($regentry.Name)
        } else {
            $regstate = $null
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            $sync.ToggleStatusCache[$ToggleSwitch] = $false
            return $false
        }
    }

    $sync.ToggleStatusCache[$ToggleSwitch] = $true
    return $true
}

# [功能说明] Get-WinUtilVariables：获取信息或资源（如：ISO/语言/依赖工具路径、系统状态等）。

function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            }
            catch {
                $null = $_
            }
        }
        return $output
    }
    return $keys
}

    # [功能说明] Initialize-InstallAppArea：脚本内部函数（用于组织代码与复用逻辑）。

    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $Border.Child = $scrollViewer

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        return $itemsControl
    }

# [功能说明] Initialize-InstallAppEntry：脚本内部函数（用于组织代码与复用逻辑）。

function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        $app = $sync.configs.applicationsHashtable.$appKey

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $app.description
        $border.Add_MouseLeftButtonUp({
            $childCheckbox = ($this.Child | Where-Object {$_.Template.TargetType -eq [System.Windows.Controls.Checkbox]})[0]
            $childCheckBox.isChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        $contentPanel = New-Object Windows.Controls.StackPanel
        $contentPanel.Orientation = "Horizontal"
        $contentPanel.VerticalAlignment = [Windows.VerticalAlignment]::Center

        $icon = New-Object Windows.Controls.Grid
        $icon.SetResourceReference([Windows.FrameworkElement]::WidthProperty, "AppEntryIconSize")
        $icon.SetResourceReference([Windows.FrameworkElement]::HeightProperty, "AppEntryIconSize")
        $icon.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
        $fallback = New-Object Windows.Controls.TextBlock
        $fallback.Text = $app.content.TrimStart(".").Substring(0, 1).ToUpper()
        $fallback.FontWeight = "Bold"; $fallback.HorizontalAlignment = "Center"; $fallback.VerticalAlignment = "Center"
        if ($app.link) { $fallback.Visibility = "Collapsed" }
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "AppEntryFontSize")
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ToggleButtonOnColor")
        [void]$icon.Children.Add($fallback)
        if ($app.link) {
            $logo = New-Object Windows.Controls.Image
            $logo.Stretch = [Windows.Media.Stretch]::Uniform
            $logo.Source = "https://www.google.com/s2/favicons?sz=64&domain_url=$([uri]::EscapeDataString($app.link))"
            $logo.Add_ImageFailed({ $this.Visibility = "Collapsed"; $this.Parent.Children[0].Visibility = "Visible" })
            [void]$icon.Children.Add($logo)
        }
        [void]$contentPanel.Children.Add($icon)

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $app.content

        # Add FOSS label after the name if FOSS
        if ($app.foss -eq $true) {
            $fossRun = [System.Windows.Documents.Run]::new(" $([char]0x25CF)")
            $fossRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(110, 255, 114))
            $fossRun.FontSize = 11.5

            [void]$appName.Inlines.Add($fossRun)
        }
        [void]$contentPanel.Children.Add($appName)
        $checkBox.Content = $contentPanel

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)

        $border.Child = $checkBox
        if ($sync.selectedApps -contains $appKey) {
            $checkBox.IsChecked = $true
        }
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }

# [功能说明] Initialize-InstallCategoryAppList：脚本内部函数（用于组织代码与复用逻辑）。

function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category before creating WPF controls.
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        $sync.InstallAppRenderQueue = [System.Collections.Queue]::new()

        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($categoryToggle)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $categoryToggle.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $categoryToggle.Content = $categoryToggle.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $categoryToggle.Content = $categoryToggle.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            $sync.InstallAppRenderQueue.Enqueue([pscustomobject]@{
                Category = $category
                TargetElement = $wrapPanel
                AppKeys = @($appsByCategory[$category] | Sort-Object)
            })
        }

        Start-WinUtilInstallAppRendering
    }

# [功能说明] Initialize-WinUtilRunspacePool：初始化后台任务使用的运行空间池。

function Initialize-WinUtilRunspacePool {
    if ($sync.runspace -and $sync.runspace.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        return $sync.runspace
    }

    if ($sync.runspace) {
        Close-WinUtilRunspacePool
    }

    # Set the maximum number of threads for the RunspacePool to the number of threads on the machine.
    $maxthreads = [Math]::Max([int]$env:NUMBER_OF_PROCESSORS, 1)

    # Create a new session state for parsing variables into our runspace.
    $hashVars = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null
    $offlineVar = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE', $PARAM_OFFLINE, $null
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $initialSessionState.Variables.Add($hashVars)
    $initialSessionState.Variables.Add($offlineVar)

    # Get every WinUtil/WPF function and add it to the session state.
    $functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
    foreach ($function in $functions) {
        $functionDefinition = Get-Content function:\$($function.Name)
        $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $functionDefinition
        $initialSessionState.Commands.Add($functionEntry)
    }

    $sync.runspace = [runspacefactory]::CreateRunspacePool(
        1,                      # Minimum thread count
        $maxthreads,            # Maximum thread count
        $initialSessionState,   # Initial session state
        $Host                   # Machine to create runspaces on
    )

    $sync.runspace.Open()
    return $sync.runspace
}

function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TabName
    )

    if ($null -eq $sync.InitializedTabs) {
        $sync.InitializedTabs = @{}
    }

    if ($sync.InitializedTabs[$TabName]) {
        return
    }

    switch ($TabName) {
        "Install" {
            Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
            Initialize-WPFUI -targetGridName "appscategory"

            Initialize-WPFUI -targetGridName "appspanel"
        }
        "Tweaks" {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
        }
        "Config" {
            Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2
        }
        "AppX" {
            Invoke-WPFUIElements -configVariable $sync.configs.appx -targetGridName "appxpanel" -columncount 2
        }
        "Win11ISO" {
            if ($sync.Form -and $sync.Form.Dispatcher) {
                $sync.Form.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-WinUtilISOCheckExistingWork }) | Out-Null
            }
        }
    }

    $sync.InitializedTabs[$TabName] = $true
}

function Initialize-WinUtilTaskbarOverlayAssets {
    param(
        [bool]$IncludeLogo = $true,
        [bool]$IncludeStatusAssets = $true
    )

    if ($IncludeLogo -and -not $sync["logorender"]) {
        $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["checkmarkrender"]) {
        $sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["warningrender"]) {
        $sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)
    }
}

# [功能说明] Install-WinUtilAPPX：安装或恢复所选 AppX 软件包。

function Install-WinUtilAPPX {
    <#

    .SYNOPSIS
        Registers a local AppX package or installs it from the Microsoft Store

    .PARAMETER Name
        The AppX package name to install

    .PARAMETER StoreId
        The optional Microsoft Store product ID used when no local manifest is available

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$StoreId
    )

    Write-WinUtilLog -Component "AppX" -Message "Installing AppX package: $Name"

    # AppX and DISM cmdlets are more reliable in Windows PowerShell 5.1. Query both installed and
    # provisioned package metadata because either can expose a local manifest that can be registered.
    $ps5Command = {
        $packageName = $args[0]
        $manifestPaths = [System.Collections.Generic.List[string]]::new()

        Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -EQ $packageName |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        $manifestPath = $manifestPaths |
            Select-Object -Unique |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if ($null -ne $manifestPath) {
            Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
            Write-Output $manifestPath
        }
    }

    $manifestOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $Name 2>&1
    if ($LASTEXITCODE -eq 0 -and $null -ne $manifestOutput) {
        $manifestPath = ($manifestOutput | Select-Object -Last 1).ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
            Write-WinUtilLog -Component "AppX" -Message "Registered local AppX manifest for $Name`: $manifestPath"
            return
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($manifestOutput | Out-String).Trim()
        Write-WinUtilLog -Level "WARN" -Component "AppX" -Message "Local AppX registration failed for $Name`: $failureDetails"
    }

    if ([string]::IsNullOrWhiteSpace($StoreId)) {
        $errorMessage = "Unable to install $Name because no local manifest or Microsoft Store ID is available."
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "No usable local manifest found for $Name. Installing Microsoft Store product $StoreId."
    Install-WinUtilWinget
    Install-WinUtilProgramWinget -Action Install -Programs @("msstore:$StoreId")
}

# [功能说明] Install-WinUtilChoco：安装软件/组件（通常调用 winget/choco 或系统安装机制）。

function Install-WinUtilChoco {
    if (-not (Get-Command -Name choco)) {
      Write-Host "Chocolatey is not installed. Installing now..."
      $installScript = Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing
      Invoke-Command -ScriptBlock ([scriptblock]::Create($installScript.Content))
    }
}

# [功能说明] Install-WinUtilProgramChoco：安装软件/组件（通常调用 winget/choco 或系统安装机制）。

function Install-WinUtilProgramChoco {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    if ($Action -eq 'Install') {
        $arguments = "install $Programs -y"
    } else {
        $arguments = "uninstall $Programs -y"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s) completed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
}

# [功能说明] Install-WinUtilProgramWinget：安装软件/组件（通常调用 winget/choco 或系统安装机制）。

Function Install-WinUtilProgramWinget {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $source = "winget"
        if ($program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        if ($Action -eq 'Install') {
            $arguments = @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent")
        } else {
            $arguments = @("uninstall", "--id", $program, "--source", $source, "--silent")
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"
        $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program (exit code: $($process.ExitCode))"
    }
}

# [功能说明] Install-WinUtilWinget：安装软件/组件（通常调用 winget/choco 或系统安装机制）。

function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}

# [功能说明] Invoke-WinUtilAssets：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  if ($render -and $null -ne $sync) {
      if ($null -eq $sync.RenderedAssetCache) {
          $sync.RenderedAssetCache = @{}
      }

      $cacheKey = "$(([string]$type).ToLowerInvariant())|$Size"
      if ($sync.RenderedAssetCache.ContainsKey($cacheKey)) {
          return $sync.RenderedAssetCache[$cacheKey]
      }
  }

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoPathData1 = @"
M 18.00,14.00
C 18.00,14.00 45.00,27.74 45.00,27.74
45.00,27.74 57.40,34.63 57.40,34.63
57.40,34.63 59.00,43.00 59.00,43.00
59.00,43.00 59.00,83.00 59.00,83.00
55.35,81.66 46.99,77.79 44.72,74.79
41.17,70.10 42.01,59.80 42.00,54.00
42.00,51.62 42.20,48.29 40.98,46.21
38.34,41.74 25.78,38.60 21.28,33.79
16.81,29.02 18.00,20.20 18.00,14.00 Z
"@
          $LogoPath1 = New-Object Windows.Shapes.Path
          $LogoPath1.Data = [Windows.Media.Geometry]::Parse($LogoPathData1)
          $LogoPath1.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData2 = @"
M 107.00,14.00
C 109.01,19.06 108.93,30.37 104.66,34.21
100.47,37.98 86.38,43.10 84.60,47.21
83.94,48.74 84.01,51.32 84.00,53.00
83.97,57.04 84.46,68.90 83.26,72.00
81.06,77.70 72.54,81.42 67.00,83.00
67.00,83.00 67.00,43.00 67.00,43.00
67.00,43.00 67.99,35.63 67.99,35.63
67.99,35.63 80.00,28.26 80.00,28.26
80.00,28.26 107.00,14.00 107.00,14.00 Z
"@
          $LogoPath2 = New-Object Windows.Shapes.Path
          $LogoPath2.Data = [Windows.Media.Geometry]::Parse($LogoPathData2)
          $LogoPath2.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData3 = @"
M 19.00,46.00
C 21.36,47.14 28.67,50.71 30.01,52.63
31.17,54.30 30.99,57.04 31.00,59.00
31.04,65.41 30.35,72.16 33.56,78.00
38.19,86.45 46.10,89.04 54.00,93.31
56.55,94.69 60.10,97.20 63.00,97.22
65.50,97.24 68.77,95.36 71.00,94.25
76.42,91.55 84.51,87.78 88.82,83.68
94.56,78.20 95.96,70.59 96.00,63.00
96.01,60.24 95.59,54.63 97.02,52.39
98.80,49.60 103.95,47.87 107.00,47.00
107.00,47.00 107.00,67.00 107.00,67.00
106.90,87.69 96.10,93.85 80.00,103.00
76.51,104.98 66.66,110.67 63.00,110.52
60.33,110.41 55.55,107.53 53.00,106.25
46.21,102.83 36.63,98.57 31.04,93.68
16.88,81.28 19.00,62.88 19.00,46.00 Z
"@
          $LogoPath3 = New-Object Windows.Shapes.Path
          $LogoPath3.Data = [Windows.Media.Geometry]::Parse($LogoPathData3)
          $LogoPath3.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a3a4a6")

          $canvas.Children.Add($LogoPath1) | Out-Null
          $canvas.Children.Add($LogoPath2) | Out-Null
          $canvas.Children.Add($LogoPath3) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()
      if ($bitmapImage.CanFreeze) {
          $bitmapImage.Freeze()
      }

      if ($null -ne $sync -and $sync.ContainsKey("RenderedAssetCache")) {
          $sync.RenderedAssetCache[$cacheKey] = $bitmapImage
      }

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}

# [功能说明] Invoke-WinUtilCurrentSystem：脚本内部函数（用于组织代码与复用逻辑）。

Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = ($_.Value.choco -split ";")[-1].Trim()
            if ($packageId -ne "na" -and $packageId -in $apps) {
                Write-Output $_.Key
            }
        }
    }

    if ($checkbox -eq "winget") {
        $originalEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
            $installedProgramOutput = @(winget list --accept-source-agreements --disable-interactivity 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "winget list failed with exit code $LASTEXITCODE."
            }
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
        $installedProgramText = $installedProgramOutput -join "`n"

        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = (($_.Value.winget -split ";")[-1] -replace "^msstore:", "").Trim()
            if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                return
            }

            $packagePattern = "(?im)[^\S\r\n]{2,}$([regex]::Escape($packageId))(?=[^\S\r\n]{2,}|$)"
            if ($installedProgramText -match $packagePattern) {
                Write-Output $_.Key
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}

# [功能说明] Invoke-WinUtilExplorerUpdate：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}

# [功能说明] Invoke-WinUtilFeatureInstall：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilFeatureInstall ($CheckBox) {
    Write-WinUtilLog -Component "Feature" -Message "Applying feature action: $CheckBox"

    if ($sync.configs.feature.$CheckBox.feature) {
        foreach ($feature in $sync.configs.feature.$CheckBox.feature) {
            Write-Host "Installing $feature"
            Write-WinUtilLog -Component "Feature" -Message "Enabling Windows optional feature: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Enabled Windows optional feature: $feature"
        }
    }

    if ($sync.configs.feature.$CheckBox.InvokeScript) {
        foreach ($script in $sync.configs.feature.$CheckBox.InvokeScript) {
            Write-Host "Running Script for $CheckBox"
            Write-WinUtilLog -Component "Feature" -Message "Running feature script for: $CheckBox"
            Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Completed feature script for: $CheckBox"
        }
    }
    Write-WinUtilLog -Component "Feature" -Message "Feature action completed: $CheckBox"
}

# [功能说明] Invoke-WinUtilFontScaling：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Store the scale factor so it can be reapplied after theme changes
    $sync.FontScaleFactor = $ScaleFactor

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }
}

# [功能说明] Invoke-WinUtilInstallPSProfile：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilInstallPSProfile {
    if (-not (Get-Command wt)) {
        Write-Host "Windows Terminal not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.WindowsTerminal --source winget --silent
    }

    if (-not (Get-Command pwsh)) {
        Write-Host "PowerShell 7 not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.PowerShell --source winget --installer-type wix --silent
    }

    wt new-tab pwsh -NoExit -Command "irm https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1 | iex"
}

function Write-WinUtilISOLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $logLine = "[$ts] $Message"
    $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
        $current = $sync["WPFWin11ISOStatusLog"].Text
        if ($current -eq "已就绪。请选择一个 Windows 11 ISO 以开始。") {
            $sync["WPFWin11ISOStatusLog"].Text = $logLine
        } else {
            $sync["WPFWin11ISOStatusLog"].Text += "`n$logLine"
        }
        $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
        $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
    })
}

function Invoke-WinUtilISOBrowse {
    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = "选择 Windows 11 ISO"
    $dlg.Filter           = "ISO 文件 (*.iso)|*.iso|所有文件 (*.*)|*.*"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $isoPath    = $dlg.FileName
    $fileSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)

    $sync["WPFWin11ISOPath"].Text           = $isoPath
    $sync["WPFWin11ISOFileInfo"].Text       = "文件大小：$fileSizeGB GB"
    $sync["WPFWin11ISOFileInfo"].Visibility = "Visible"
    $sync["WPFWin11ISOMountSection"].Visibility       = "Visible"
    $sync["WPFWin11ISOVerifyResultPanel"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility      = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility      = "Collapsed"

    Write-WinUtilISOLog "已选择 ISO：$isoPath  ($fileSizeGB GB)"
}

function Invoke-WinUtilISOMountAndVerify {
    $isoPath = $sync["WPFWin11ISOPath"].Text

    if ([string]::IsNullOrWhiteSpace($isoPath) -or $isoPath -eq "尚未选择 ISO...") {
        [System.Windows.MessageBox]::Show("请先选择 ISO 文件。", "未选择 ISO", "OK", "Warning")
        return
    }

    Write-WinUtilISOLog "正在挂载 ISO：$isoPath"
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在挂载 ISO..." -Percent 10
    $sync["WPFWin11ISOBrowseButton"].IsEnabled = $false
    $sync["WPFWin11ISOMountButton"].IsEnabled = $false
    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    Invoke-WPFRunspace -ParameterList @(,('isoPath', $isoPath)) -ScriptBlock {
        param($isoPath)

        try {
            Mount-DiskImage -ImagePath $isoPath

            do {
                Start-Sleep -Milliseconds 500
            } until ((Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter)

            $driveLetter = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter + ":"
            Write-WinUtilISOLog "已挂载到驱动器 $driveLetter"

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在验证 ISO 内容..." -Percent 30

            $wimPath = Join-Path $driveLetter "sources\install.wim"
            $esdPath = Join-Path $driveLetter "sources\install.esd"

            if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
                Dismount-DiskImage -ImagePath $isoPath
                Write-WinUtilISOLog "错误：未找到 install.wim/install.esd，这不是有效的 Windows ISO。"
                Invoke-WPFUIThread {
                    [System.Windows.MessageBox]::Show(
                        "这似乎不是有效的 Windows ISO。`n`n未找到 install.wim / install.esd。",
                        "无效的 ISO", "OK", "Error")
                }
                return
            }

            $activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在读取镜像元数据..." -Percent 55
            $imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName

            if (-not ($imageInfo | Where-Object { $_.ImageName -match "Windows 11" })) {
                Dismount-DiskImage -ImagePath $isoPath
                Write-WinUtilISOLog "错误：镜像中未找到 Windows 11 版本。"
                Invoke-WPFUIThread {
                    [System.Windows.MessageBox]::Show(
                        "此 ISO 中未找到 Windows 11 版本。`n`n仅支持微软官方 Windows 11 ISO。",
                        "不是 Windows 11 ISO", "OK", "Error")
                }
                return
            }

            $sync["Win11ISOImageInfo"] = $imageInfo
            $sync["Win11ISODriveLetter"] = $driveLetter
            $sync["Win11ISOWimPath"]     = $activeWim
            $sync["Win11ISOImagePath"]   = $isoPath

            Invoke-WPFUIThread {
                $sync["WPFWin11ISOMountDriveLetter"].Text = "挂载位置：$driveLetter   |   镜像文件：$(Split-Path $activeWim -Leaf)"
                $sync["WPFWin11ISOEditionComboBox"].Items.Clear()
                foreach ($img in $imageInfo) {
                    [void]$sync["WPFWin11ISOEditionComboBox"].Items.Add("$($img.ImageIndex): $($img.ImageName)")
                }
                if ($sync["WPFWin11ISOEditionComboBox"].Items.Count -gt 0) {
                    $proIndex = -1
                    for ($i = 0; $i -lt $sync["WPFWin11ISOEditionComboBox"].Items.Count; $i++) {
                        if ($sync["WPFWin11ISOEditionComboBox"].Items[$i] -match "Windows 11 Pro(?![\w ])") {
                            $proIndex = $i; break
                        }
                    }
                    $sync["WPFWin11ISOEditionComboBox"].SelectedIndex = if ($proIndex -ge 0) { $proIndex } else { 0 }
                }
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Visible"
                $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
            }

            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "ISO 验证完成" -Percent 100
            Write-WinUtilISOLog "ISO 验证通过。找到版本数：$($imageInfo.Count)"
        } catch {
            $errorMessage = $_
            Write-WinUtilISOLog "挂载或验证时出错：$errorMessage"
            Invoke-WPFUIThread {
                [System.Windows.MessageBox]::Show(
                    "挂载或验证 ISO 时发生错误：`n`n$errorMessage",
                    "错误", "OK", "Error")
            }
        } finally {
            Start-Sleep -Milliseconds 800
            Set-WinUtilTweaksProgressIndicator -Visible $false
            Invoke-WPFUIThread {
                $sync["WPFWin11ISOBrowseButton"].IsEnabled = $true
                $sync["WPFWin11ISOMountButton"].IsEnabled = $true
                $sync["Win11ISOProcessRunning"] = $false
            }
        }
    }
}

function Invoke-WinUtilISOModify {
    $isoPath     = $sync["Win11ISOImagePath"]
    $driveLetter = $sync["Win11ISODriveLetter"]
    $wimPath     = $sync["Win11ISOWimPath"]

    if (-not $isoPath) {
        [System.Windows.MessageBox]::Show(
            "未找到已验证的 ISO。请先完成步骤 1 和 2。",
            "尚未就绪", "OK", "Warning")
        return
    }

    $selectedItem     = $sync["WPFWin11ISOEditionComboBox"].SelectedItem
    $selectedWimIndex = 1
    if ($selectedItem -and $selectedItem -match '^(\d+):') {
        $selectedWimIndex = [int]$Matches[1]
    } elseif ($sync["Win11ISOImageInfo"]) {
        $selectedWimIndex = $sync["Win11ISOImageInfo"][0].ImageIndex
    }
    $selectedEditionName = if ($selectedItem) { ($selectedItem -replace '^\d+:\s*', '') } else { "未知" }
    Write-WinUtilISOLog "已选择版本：$selectedEditionName（索引 $selectedWimIndex）"

    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOModifying"] = $true
    $sync["Win11ISOProcessRunning"] = $true

    $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path $workDir) {
        $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
    }

    $autounattendContent = if ($WinUtilAutounattendXml) {
        $WinUtilAutounattendXml
    } else {
        $toolsXml = Join-Path $PSScriptRoot "..\..\tools\autounattend.xml"
        if (Test-Path $toolsXml) { Get-Content $toolsXml -Raw } else { "" }
    }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $injectDrivers = $sync["WPFWin11ISOInjectDrivers"].IsChecked -eq $true
    $runspace.SessionStateProxy.SetVariable("sync",                $sync)
    $runspace.SessionStateProxy.SetVariable("isoPath",             $isoPath)
    $runspace.SessionStateProxy.SetVariable("driveLetter",         $driveLetter)
    $runspace.SessionStateProxy.SetVariable("wimPath",             $wimPath)
    $runspace.SessionStateProxy.SetVariable("workDir",             $workDir)
    $runspace.SessionStateProxy.SetVariable("selectedWimIndex",    $selectedWimIndex)
    $runspace.SessionStateProxy.SetVariable("selectedEditionName", $selectedEditionName)
    $runspace.SessionStateProxy.SetVariable("autounattendContent", $autounattendContent)
    $runspace.SessionStateProxy.SetVariable("injectDrivers",       $injectDrivers)

    $isoScriptFuncDef   = "function Invoke-WinUtilISOScript {`n" + ${function:Invoke-WinUtilISOScript}.ToString() + "`n}"
    $win11ISOLogFuncDef = "function Write-WinUtilISOLog {`n"     + ${function:Write-WinUtilISOLog}.ToString()     + "`n}"
    $runspace.SessionStateProxy.SetVariable("isoScriptFuncDef",   $isoScriptFuncDef)
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($isoScriptFuncDef))
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-WinUtilEditionIdFromName {
            param([string]$EditionName)

            $normalizedName = ($EditionName -replace '^Windows\s+11\s+', '').Trim()
            switch -Regex ($normalizedName) {
                '^Home Single Language$'      { return 'CoreSingleLanguage' }
                '^Home N$'                    { return 'CoreN' }
                '^Home$'                      { return 'Core' }
                '^Pro for Workstations N$'    { return 'ProfessionalWorkstationN' }
                '^Pro for Workstations$'      { return 'ProfessionalWorkstation' }
                '^Pro Education N$'           { return 'ProfessionalEducationN' }
                '^Pro Education$'             { return 'ProfessionalEducation' }
                '^Pro N$'                     { return 'ProfessionalN' }
                '^Pro$'                       { return 'Professional' }
                '^Education N$'               { return 'EducationN' }
                '^Education$'                 { return 'Education' }
                '^Enterprise LTSC N$'         { return 'EnterpriseSN' }
                '^Enterprise LTSC$'           { return 'EnterpriseS' }
                '^Enterprise N$'              { return 'EnterpriseN' }
                '^Enterprise$'                { return 'Enterprise' }
                default                       { return '' }
            }
        }

        try {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
            })

            Log "正在创建工作目录：$workDir"
            $isoContents = Join-Path $workDir "iso_contents"
            New-Item -ItemType Directory -Path $isoContents -Force
            SetProgress "正在复制 ISO 内容..." 10

            Log "正在从 $driveLetter 复制 ISO 内容到 $isoContents..."
            & robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS
            Log "ISO 内容复制完成。"
            SetProgress "正在准备安装介质..." 25

            $sourceImageFileName = Split-Path $wimPath -Leaf
            $localWim = Join-Path $isoContents "sources\$sourceImageFileName"
            if (-not (Test-Path $localWim)) {
                throw "Copied ISO image file not found: sources\$sourceImageFileName"
            }
            $selectedEditionId = Get-WinUtilEditionIdFromName -EditionName $selectedEditionName

            Log "正在写入 autounattend.xml 和版本选择配置..."
            Invoke-WinUtilISOScript -ISOContentsDir $isoContents -AutoUnattendXml $autounattendContent -InjectCurrentSystemDrivers $injectDrivers -InstallImagePath $localWim -InstallImageIndex $selectedWimIndex -InstallEditionId $selectedEditionId -Log { param($m) Log $m }

            SetProgress "正在保留安装镜像..." 70
            if ($injectDrivers) {
                Log "Added current-system drivers to $sourceImageFileName index $selectedWimIndex with one mount and commit."
            } else {
                Log "Preserved the original $sourceImageFileName without mounting, exporting, or modifying it."
            }

            SetProgress "正在卸载源 ISO..." 80
            Log "正在卸载原始 ISO..."
            Dismount-DiskImage -ImagePath $isoPath

            $sync["Win11ISOWorkDir"]     = $workDir
            $sync["Win11ISOContentsDir"] = $isoContents

            SetProgress "修改完成" 100
            Log "install.wim 修改完成。请在步骤 4 中选择输出方式。"

            $sync["WPFWin11ISOOutputSection"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"
            })
        } catch {
            Log "修改过程中出错：$_"

            try {
                $mountedISO = Get-DiskImage -ImagePath $isoPath
                if ($mountedISO -and $mountedISO.Attached) {
                    Log "Cleaning up: dismounting source ISO..."
                    Dismount-DiskImage -ImagePath $isoPath
                }
            } catch { Log "Warning: could not dismount ISO during cleanup: $_" }

            try {
                if (Test-Path $workDir) {
                    Log "Cleaning up: removing temp directory $workDir..."
                    Remove-Item -Path $workDir -Recurse -Force
                }
            } catch { Log "Warning: could not remove temp directory during cleanup: $_" }

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "修改 install.wim 时发生错误：`n`n$_",
                    "修改错误", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOModifying"] = $false
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
                if ($sync["WPFWin11ISOOutputSection"].Visibility -ne "Visible") {
                    $sync["WPFWin11ISOSelectSection"].Visibility = "Visible"
                    $sync["WPFWin11ISOMountSection"].Visibility  = "Visible"
                    $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                }
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOCheckExistingWork {
    if ($sync["Win11ISOContentsDir"] -and (Test-Path $sync["Win11ISOContentsDir"])) { return }

    # Check if ISO modification is currently in progress
    if ($sync["Win11ISOModifying"]) {
        return
    }

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $existingWorkDir) { return }

    $isoContents = Join-Path $existingWorkDir.FullName "iso_contents"
    if (-not (Test-Path $isoContents)) { return }

    $sync["Win11ISOWorkDir"]     = $existingWorkDir.FullName
    $sync["Win11ISOContentsDir"] = $isoContents

    $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"

    $modified = $existingWorkDir.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
    Write-WinUtilISOLog "找到现有工作目录：$($existingWorkDir.FullName)"
    Write-WinUtilISOLog "最后修改时间：$modified - 跳过步骤 1-3，从步骤 4 继续。"
    Write-WinUtilISOLog "如需改用新的 ISO 重新开始，请点击“清理并重置”。"

    [System.Windows.MessageBox]::Show(
        "发现之前的 WinUtil ISO 工作目录：`n`n$($existingWorkDir.FullName)`n`n（最后修改：$modified）`n`n已恢复步骤 4（输出选项），你可以保存已修改的镜像。`n`n如需重新开始，请在步骤 4 点击“清理并重置”。",
        "找到现有工作目录", "OK", "Info")
}

function Invoke-WinUtilISOCleanAndReset {
    $workDir = $sync["Win11ISOWorkDir"]

    if ($workDir -and (Test-Path $workDir)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "这将删除临时工作目录：`n`n$workDir`n`n并把界面重置到开始状态。`n`n是否继续？",
            "清理并重置", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
    }

    $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",    $sync)
    $runspace.SessionStateProxy.SetVariable("workDir", $workDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            if ($workDir) {
                $mountDir = Join-Path $workDir "wim_mount"
                try {
                    $mountedImages = Get-WindowsImage -Mounted |
                                     Where-Object { $_.Path -like "$workDir*" }
                    if ($mountedImages) {
                        foreach ($img in $mountedImages) {
                            Log "Dismounting WIM at: $($img.Path) (discarding changes)..."
                            SetProgress "Dismounting WIM image..." 3
                            Dismount-WindowsImage -Path $img.Path -Discard
                            Log "WIM dismounted successfully."
                        }
                    } elseif (Test-Path $mountDir) {
                        Log "No mounted WIM reported by Get-WindowsImage. Running DISM /Cleanup-Wim as a precaution..."
                        SetProgress "Running DISM cleanup..." 3
                        & dism /English /Cleanup-Wim | ForEach-Object { Log $_ }
                    }
                } catch {
                    Log "Warning: could not dismount WIM cleanly. Attempting DISM /Cleanup-Wim fallback: $_"
                    try { & dism /English /Cleanup-Wim | ForEach-Object { Log $_ } }
                    catch { Log "Warning: DISM /Cleanup-Wim also failed: $_" }
                }
            }

            if ($workDir -and (Test-Path $workDir)) {
                Log "Scanning files to delete in: $workDir"
                SetProgress "Scanning files..." 5

                $allFiles = @(Get-ChildItem -Path $workDir -File -Recurse -Force)
                $allDirs  = @(Get-ChildItem -Path $workDir -Directory -Recurse -Force |
                    Sort-Object { $_.FullName.Length } -Descending)
                $total   = $allFiles.Count
                $deleted = 0

                Log "Found $total files to delete."

                foreach ($f in $allFiles) {
                    try { Remove-Item -Path $f.FullName -Force } catch { Log "WARNING: could not delete $($f.FullName): $_" }
                    $deleted++
                    if ($deleted % 100 -eq 0 -or $deleted -eq $total) {
                        $pct = [math]::Round(($deleted / [Math]::Max($total, 1)) * 85) + 5
                        SetProgress "Deleting files in $($f.Directory.Name)... ($deleted / $total)" $pct
                    }
                }

                foreach ($d in $allDirs) {
                    try { Remove-Item -Path $d.FullName -Force } catch { Log "WARNING: could not delete $($d.FullName): $_" }
                }

                try { Remove-Item -Path $workDir -Recurse -Force } catch { Log "WARNING: could not delete temp directory ${workDir}: $_" }

                if (Test-Path $workDir) {
                    Log "WARNING: some items could not be deleted in $workDir"
                } else {
                    Log "Temp directory deleted successfully."
                }
            } else {
                Log "No temp directory found - resetting UI."
            }

            SetProgress "正在重置界面..." 95
            Log "正在重置界面..."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["Win11ISOWorkDir"]     = $null
                $sync["Win11ISOContentsDir"] = $null
                $sync["Win11ISOImagePath"]   = $null
                $sync["Win11ISODriveLetter"] = $null
                $sync["Win11ISOWimPath"]     = $null
                $sync["Win11ISOImageInfo"]   = $null
                $sync["Win11ISOUSBDisks"]    = $null

                $sync["WPFWin11ISOPath"].Text                   = "尚未选择 ISO..."
                $sync["WPFWin11ISOFileInfo"].Visibility          = "Collapsed"
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Collapsed"
                $sync["WPFWin11ISOOptionUSB"].Visibility         = "Collapsed"
                $sync["WPFWin11ISOOutputSection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility      = "Collapsed"
                $sync["WPFWin11ISOSelectSection"].Visibility     = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled       = $true
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled   = $true

                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0

                $sync["WPFWin11ISOStatusLog"].Text   = "已就绪。请选择一个 Windows 11 ISO 以开始。"
            })
        } catch {
            Log "ERROR during Clean & Reset: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $true
            })
        } finally {
            $sync["Win11ISOProcessRunning"] = $false
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOExport {
    $contentsDir = $sync["Win11ISOContentsDir"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show(
            "未找到修改后的 ISO 内容。请先完成步骤 1-3。",
            "尚未就绪", "OK", "Warning")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title            = "保存修改后的 Windows 11 ISO"
    $dlg.Filter           = "ISO 文件 (*.iso)|*.iso"
    $dlg.FileName         = "Win11_Modified_$(Get-Date -Format 'yyyyMMdd').iso"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $outputISO = $dlg.FileName

    # Locate oscdimg.exe (Windows ADK or winget per-user install)
    $oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "oscdimg.exe" |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) {
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $oscdimg) {
        Write-WinUtilISOLog "未找到 oscdimg.exe，正在尝试通过 winget 安装..."
        try {
            # First ensure winget is installed and operational
            Install-WinUtilWinget

            $winget = Get-Command winget
            $result = & $winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
            Write-WinUtilISOLog "winget 输出：$result"
            $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                       Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                       Select-Object -First 1 -ExpandProperty FullName
        } catch {
            Write-WinUtilISOLog "winget 不可用或安装失败：$_"
        }

        if (-not $oscdimg) {
            Write-WinUtilISOLog "尝试安装后仍未找到 oscdimg.exe。"
            [System.Windows.MessageBox]::Show(
                "无法找到或自动安装 oscdimg.exe。`n`n请手动安装：`n  winget install -e --id Microsoft.OSCDIMG`n`n或从以下地址安装 Windows ADK：`nhttps://learn.microsoft.com/windows-hardware/get-started/adk-install",
                "未找到 oscdimg", "OK", "Warning")
            return
        }
        Write-WinUtilISOLog "oscdimg.exe 安装成功。"
    }

    $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)
    $runspace.SessionStateProxy.SetVariable("outputISO",   $outputISO)
    $runspace.SessionStateProxy.SetVariable("oscdimg",     $oscdimg)

    $win11ISOLogFuncDef = "function Write-WinUtilISOLog {`n" + ${function:Write-WinUtilISOLog}.ToString() + "`n}"
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            Write-WinUtilISOLog "正在导出 ISO：$outputISO"
            SetProgress "正在生成 ISO..." 10

            $bootData    = "2#p0,e,b`"$contentsDir\boot\etfsboot.com`"#pEF,e,b`"$contentsDir\efi\microsoft\boot\efisys.bin`""
            $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l`"CTOS_MODIFIED`"", "`"$contentsDir`"", "`"$outputISO`"")

            Write-WinUtilISOLog "正在运行 oscdimg..."

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $oscdimg
            $psi.Arguments              = $oscdimgArgs -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start()

            # Stream stdout line-by-line as oscdimg runs
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-WinUtilISOLog $line }
            }

            $proc.WaitForExit()

            # Flush any stderr after process exits
            $stderr = $proc.StandardError.ReadToEnd()
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-WinUtilISOLog "[stderr]$line" }
            }

            if ($proc.ExitCode -eq 0) {
                SetProgress "ISO 导出完成" 100
                Write-WinUtilISOLog "ISO 导出成功：$outputISO"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show("ISO 导出成功！`n`n$outputISO", "导出完成", "OK", "Info")
                })
            } else {
                Write-WinUtilISOLog "oscdimg 已退出，代码：$($proc.ExitCode)。"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show(
                        "oscdimg 已退出，代码：$($proc.ExitCode)。`n请查看状态日志了解详情。",
                        "导出错误", "OK", "Error")
                })
            }
        } catch {
            Write-WinUtilISOLog "导出 ISO 时出错：$_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("ISO 导出失败：`n`n$_", "错误", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOScript {
    <#
    .SYNOPSIS
        Prepares copied Windows setup media without modifying its install image.

    .DESCRIPTION
        Stages WinUtil's AppX removal, registry tweaks, and scheduled-task cleanup
        in the answer file for first logon, writes sources\ei.cfg for the selected
        edition, and optionally adds current-system drivers to one install.wim index.

    .PARAMETER ISOContentsDir
        Root directory of the copied ISO contents.

    .PARAMETER AutoUnattendXml
        Full XML content for autounattend.xml.

    .PARAMETER InstallEditionId
        Windows setup EditionID for sources\ei.cfg, for example Professional or Core.

    .PARAMETER InstallImagePath
        Copied install.wim to service when current-system driver injection is enabled.

    .PARAMETER InstallImageIndex
        Selected edition index in install.wim.

    .PARAMETER Log
        Optional ScriptBlock for progress/status logging. Receives a single [string] argument.
    #>
    param (
        [Parameter(Mandatory)][string]$ISOContentsDir,
        [string]$AutoUnattendXml = "",
        [bool]$InjectCurrentSystemDrivers = $false,
        [string]$InstallEditionId = "",
        [string]$InstallImagePath = "",
        [int]$InstallImageIndex = 1,
        [scriptblock]$Log = { param($m) Write-Output $m }
    )

    function Add-WinUtilISOStagedDrivers {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [Parameter(Mandatory)][string]$InstallImagePath,
            [Parameter(Mandatory)][int]$InstallImageIndex,
            [scriptblock]$Logger
        )

        function Copy-WinUtilISODriverFolder {
            param (
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Destination
            )

            $folderName = Split-Path $Source -Leaf
            $targetPath = Join-Path $Destination $folderName
            $suffix = 1
            while (Test-Path -LiteralPath $targetPath) {
                $targetPath = Join-Path $Destination "${folderName}_$suffix"
                $suffix++
            }

            Copy-Item -LiteralPath $Source -Destination $targetPath -Recurse -Force -ErrorAction Stop
            return $targetPath
        }

        function Test-WinUtilISOStorageDriver {
            param ([Parameter(Mandatory)][System.IO.FileInfo]$InfFile)

            if ($InfFile.BaseName -match '(?i)(iaahci|iastor|vmd|irst|rst)') {
                return $true
            }

            try {
                return (Get-Content -LiteralPath $InfFile.FullName -Raw -ErrorAction Stop) -match '(?im)^\s*Class\s*=\s*(SCSIAdapter|HDC)\s*(?:;.*)?$'
            } catch {
                & $Logger "Warning: could not classify storage driver '$($InfFile.FullName)': $_"
                return $false
            }
        }

        function Invoke-WinUtilISODism {
            param (
                [Parameter(Mandatory)][string[]]$Arguments,
                [Parameter(Mandatory)][string]$Operation
            )

            $output = @(& dism.exe @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                foreach ($line in @($output | Select-Object -Last 20)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                        & $Logger "  dism[$Operation]: $line"
                    }
                }
                throw "DISM $Operation failed with exit code $exitCode."
            }
            if ($Operation -ne 'metadata') {
                & $Logger "DISM $Operation completed."
            }
            return $output
        }

        function Get-WinUtilISOWimMetadata {
            param ([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][int]$Index)

            $metadata = @{}
            $output = Invoke-WinUtilISODism -Arguments @('/English', '/Get-WimInfo', "/WimFile:$ImagePath", "/Index:$Index") -Operation 'metadata'
            foreach ($line in $output) {
                if ([string]$line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
                    $metadata[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
            return $metadata
        }

        function Assert-WinUtilISOWimMetadata {
            param (
                [Parameter(Mandatory)][hashtable]$Before,
                [hashtable]$After
            )

            foreach ($key in 'Languages', 'Installation', 'Edition', 'ProductSuite', 'ProductType') {
                $beforeValue = [string]$Before[$key]
                if ($beforeValue -eq '<undefined>' -or ($key -in 'Installation', 'Edition', 'ProductType' -and [string]::IsNullOrWhiteSpace($beforeValue))) {
                    throw "install.wim metadata is already invalid: $key is undefined. Driver injection was not attempted."
                }
                if ($After) {
                    $afterValue = [string]$After[$key]
                    if ($afterValue -eq '<undefined>' -or ($beforeValue -and $afterValue -ne $beforeValue)) {
                        throw "install.wim metadata validation failed after driver injection: $key changed from '$beforeValue' to '$afterValue'."
                    }
                }
            }
        }

        function Test-WinUtilISOMountedImage {
            param ([Parameter(Mandatory)][string]$Path)

            return @(& dism.exe /English /Get-MountedImageInfo 2>$null) -match [regex]::Escape($Path)
        }

        if ([IO.Path]::GetExtension($InstallImagePath) -ne '.wim') {
            throw 'Current-system driver injection requires install.wim; install.esd cannot be serviced in place.'
        }
        if (-not (Test-Path -LiteralPath $InstallImagePath)) {
            throw "install.wim was not found: $InstallImagePath"
        }
        if ($InstallImageIndex -lt 1) {
            throw 'Current-system driver injection requires a valid install.wim image index.'
        }

        $driverExportRoot = Join-Path $env:TEMP "WinUtil_DriverExport_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
        $mountDir = Join-Path (Split-Path -Path $ContentRoot -Parent) 'wim_mount'
        New-Item -Path $driverExportRoot -ItemType Directory -Force | Out-Null
        $imageMounted = $false

        try {
            & $Logger "Exporting current system drivers before modifying install.wim..."
            $dismLog = Join-Path $env:TEMP "WinUtil_DismDriverExport_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            $dismProcess = Start-Process -FilePath "dism.exe" -ArgumentList "/online /export-driver /destination:`"$driverExportRoot`" /LogPath:`"$dismLog`"" -Wait -NoNewWindow -PassThru
            if ($dismProcess.ExitCode -ne 0) {
                throw "dism.exe driver export failed with exit code $($dismProcess.ExitCode)."
            }

            $driverInfs = @(Get-ChildItem -Path $driverExportRoot -Filter '*.inf' -Recurse -File)
            if ($driverInfs.Count -eq 0) {
                throw 'DISM exported no driver INF files.'
            }
            $driverFolders = @($driverInfs | Group-Object { $_.Directory.FullName })
            $winpeDriverDir = Join-Path $ContentRoot '$WinpeDriver$'
            $storageCount = 0
            $copyFailures = 0

            foreach ($driverFolderGroup in $driverFolders) {
                $driverFolder = [string]$driverFolderGroup.Name
                $storageInfs = @($driverFolderGroup.Group | Where-Object { Test-WinUtilISOStorageDriver -InfFile $_ })
                if ($storageInfs.Count -eq 0) {
                    continue
                }

                try {
                    New-Item -Path $winpeDriverDir -ItemType Directory -Force | Out-Null
                    $winpeTarget = Copy-WinUtilISODriverFolder -Source $driverFolder -Destination $winpeDriverDir
                    $storageCount++
                    & $Logger "Staged boot-storage package '$driverFolder' for WinPE as '$winpeTarget'."
                } catch {
                    $copyFailures++
                    & $Logger "Warning: failed to stage boot-storage package '$driverFolder': $_"
                }
            }

            if ($copyFailures -gt 0) {
                throw "Failed to stage $copyFailures boot-storage driver package folders."
            }

            & $Logger "Exported $($driverInfs.Count) driver INF files across $($driverFolders.Count) package folders; staged $storageCount boot-storage packages for WinPE."
            $metadataBefore = Get-WinUtilISOWimMetadata -ImagePath $InstallImagePath -Index $InstallImageIndex
            Assert-WinUtilISOWimMetadata -Before $metadataBefore

            Set-ItemProperty -LiteralPath $InstallImagePath -Name IsReadOnly -Value $false
            New-Item -Path $mountDir -ItemType Directory -Force | Out-Null
            & $Logger "Mounting install.wim index $InstallImageIndex once for driver injection..."
            Invoke-WinUtilISODism -Arguments @('/English', '/Mount-Image', "/ImageFile:$InstallImagePath", "/Index:$InstallImageIndex", "/MountDir:$mountDir") -Operation 'mount' | Out-Null
            $imageMounted = $true

            & $Logger "Adding all exported drivers to the selected Windows image in one DISM operation..."
            Invoke-WinUtilISODism -Arguments @('/English', "/Image:$mountDir", '/Add-Driver', "/Driver:$driverExportRoot", '/Recurse') -Operation 'add-driver' | Out-Null

            & $Logger 'Committing the driver-only install.wim change...'
            Invoke-WinUtilISODism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Commit') -Operation 'commit' | Out-Null
            $imageMounted = $false

            $metadataAfter = Get-WinUtilISOWimMetadata -ImagePath $InstallImagePath -Index $InstallImageIndex
            Assert-WinUtilISOWimMetadata -Before $metadataBefore -After $metadataAfter
            & $Logger 'Driver injection complete; install.wim metadata validation passed.'
        } finally {
            if ($imageMounted -or (Test-WinUtilISOMountedImage -Path $mountDir)) {
                try {
                    Invoke-WinUtilISODism -Arguments @('/English', '/Unmount-Image', "/MountDir:$mountDir", '/Discard') -Operation 'discard' | Out-Null
                } catch {
                    & $Logger "Warning: could not discard the failed install.wim mount: $_"
                }
            }
            Remove-Item -Path $mountDir -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $driverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Write-WinUtilISOEditionConfig {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [string]$EditionId,
            [scriptblock]$Logger
        )

        $sourcesDir = Join-Path $ContentRoot "sources"
        New-Item -Path $sourcesDir -ItemType Directory -Force | Out-Null

        $pidPath = Join-Path $sourcesDir "PID.txt"
        if (Test-Path $pidPath) {
            Remove-Item -Path $pidPath -Force
            & $Logger "Removed sources\PID.txt so setup will not force a stale or mismatched product key."
        }

        if ([string]::IsNullOrWhiteSpace($EditionId)) {
            & $Logger "Warning: selected edition ID is unknown - skipping sources\ei.cfg fallback."
            return
        }

        $eiCfgPath = Join-Path $sourcesDir "ei.cfg"
        $eiCfg = @"
[EditionID]
$EditionId
[Channel]
Retail
[VL]
0
"@.Trim()

        Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
        & $Logger "Written sources\ei.cfg for EditionID '$EditionId'."
    }

    function Add-WinUtilISOSetupCustomizations {
        param (
            [Parameter(Mandatory)][string]$XmlContent,
            [Parameter(Mandatory)][int]$InstallImageIndex,
            [scriptblock]$Logger
        )

        $appxPackages = @(
            'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingSearch',
            'Microsoft.BingWeather', 'Microsoft.GetHelp', 'Microsoft.MicrosoftOfficeHub',
            'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftStickyNotes',
            'Microsoft.OutlookForWindows', 'Microsoft.Paint', 'Microsoft.PowerAutomateDesktop',
            'Microsoft.StartExperiencesApp', 'Microsoft.Todos', 'Microsoft.Windows.DevHome',
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsSoundRecorder',
            'Microsoft.ZuneMusic', 'MicrosoftCorporationII.QuickAssist', 'MSTeams'
        )

        $appxList = ($appxPackages | ForEach-Object { "    '$_'" }) -join "`r`n"
        $postInstallScript = @"
`$ErrorActionPreference = 'Continue'
`$logPath = 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.log'
Start-Transcript -Path `$logPath -Append -ErrorAction SilentlyContinue

try {
    Write-Host 'WinUtil: Removing provisioned AppX packages...'
    `$packages = @(
$appxList
    )
    foreach (`$package in `$packages) {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { `$_.DisplayName -like "*`$package*" } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName `$_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { `$_.Name -like "*`$package*" } |
            ForEach-Object { Remove-AppxPackage -AllUsers -Package `$_.PackageFullName -ErrorAction SilentlyContinue | Out-Null }
    }

    function Set-WinUtilRegistryValue([string]`$Path, [string]`$Name, [string]`$Type, [string]`$Value) {
        reg.exe add `$Path /v `$Name /t `$Type /d `$Value /f 2>&1 | Out-Null
    }

    function Set-WinUtilContentDeliveryManagerValues([string]`$HiveRoot) {
        `$contentDeliveryManager = "`$HiveRoot\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Set-WinUtilRegistryValue `$contentDeliveryManager 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'ContentDeliveryAllowed' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'FeatureManagementEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SoftLandingEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContentEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue `$contentDeliveryManager 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
        reg.exe delete "`$contentDeliveryManager\Subscriptions" /f 2>&1 | Out-Null
        reg.exe delete "`$contentDeliveryManager\SuggestedApps" /f 2>&1 | Out-Null
    }

    Write-Host 'WinUtil: Applying registry tweaks...'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' /f 2>&1 | Out-Null
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' /f 2>&1 | Out-Null
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer' 'REG_SZ' 'http://localhost:8080'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUStatusServer' 'REG_SZ' 'http://localhost:8080'
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' 'workCompleted' 'REG_DWORD' '1'
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' /f 2>&1 | Out-Null
    Set-WinUtilRegistryValue 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\BITS' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\wuauserv' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\UsoSvc' 'Start' 'REG_DWORD' '4'
    Set-WinUtilRegistryValue 'HKLM\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc' 'Start' 'REG_DWORD' '4'

    `$defaultHive = 'HKU\WinUtilDefault'
    reg.exe load `$defaultHive 'C:\Users\Default\NTUSER.DAT' 2>&1 | Out-Null
    if (`$LASTEXITCODE -eq 0) {
        Set-WinUtilRegistryValue "`$defaultHive\Control Panel\UnsupportedHardwareNotificationCache" 'SV1' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Control Panel\UnsupportedHardwareNotificationCache" 'SV2' 'REG_DWORD' '0'
        Set-WinUtilContentDeliveryManagerValues `$defaultHive
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" 'HasAccepted' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Input\TIPC" 'Enabled' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\InputPersonalization\TrainedDataStore" 'HarvestContacts' 'REG_DWORD' '0'
        Set-WinUtilRegistryValue "`$defaultHive\Software\Microsoft\Personalization\Settings" 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
        reg.exe unload `$defaultHive 2>&1 | Out-Null
    }

    Set-WinUtilContentDeliveryManagerValues 'HKCU'
    Set-WinUtilRegistryValue 'HKCU\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-WinUtilRegistryValue 'HKCU\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'

    Write-Host 'WinUtil: Removing scheduled task definitions...'
    `$taskPaths = @(
        'C:\Windows\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Chkdsk\Proxy',
        'C:\Windows\System32\Tasks\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        'C:\Windows\System32\Tasks\Microsoft\Windows\InstallService',
        'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateOrchestrator',
        'C:\Windows\System32\Tasks\Microsoft\Windows\UpdateAssistant',
        'C:\Windows\System32\Tasks\Microsoft\Windows\WaaSMedic',
        'C:\Windows\System32\Tasks\Microsoft\Windows\WindowsUpdate',
        'C:\Windows\System32\Tasks\Microsoft\WindowsUpdate'
    )
    foreach (`$taskPath in `$taskPaths) { Remove-Item -LiteralPath `$taskPath -Recurse -Force -ErrorAction SilentlyContinue }

    Start-Process -FilePath 'C:\Windows\System32\OneDriveSetup.exe' -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue
    Write-Host 'WinUtil: Post-install customization complete.'
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
"@

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')

        $setupComponent = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]', $nsMgr)
        $extensions = $xmlDoc.SelectSingleNode('//sg:Extensions', $nsMgr)
        $firstLogonFile = $xmlDoc.SelectSingleNode('//sg:File[@path="C:\Windows\Setup\Scripts\FirstLogon.ps1"]', $nsMgr)
        if (-not $setupComponent -or -not $extensions -or -not $firstLogonFile) {
            throw 'autounattend.xml is missing a required Windows Setup, Extensions, or FirstLogon.ps1 node.'
        }

        $imageInstall = $setupComponent.SelectSingleNode('u:ImageInstall', $nsMgr)
        if (-not $imageInstall) {
            $imageInstall = $xmlDoc.CreateElement('ImageInstall', $setupComponent.NamespaceURI)
            [void]$setupComponent.AppendChild($imageInstall)
        }
        $osImage = $imageInstall.SelectSingleNode('u:OSImage', $nsMgr)
        if (-not $osImage) {
            $osImage = $xmlDoc.CreateElement('OSImage', $setupComponent.NamespaceURI)
            [void]$imageInstall.AppendChild($osImage)
        }
        $installFrom = $osImage.SelectSingleNode('u:InstallFrom', $nsMgr)
        if (-not $installFrom) {
            $installFrom = $xmlDoc.CreateElement('InstallFrom', $setupComponent.NamespaceURI)
            [void]$osImage.AppendChild($installFrom)
        }
        foreach ($existingMetadata in @($installFrom.SelectNodes('u:MetaData', $nsMgr))) {
            [void]$installFrom.RemoveChild($existingMetadata)
        }
        $metadata = $xmlDoc.CreateElement('MetaData', $setupComponent.NamespaceURI)
        $action = $xmlDoc.CreateAttribute('wcm', 'action', 'http://schemas.microsoft.com/WMIConfig/2002/State')
        $action.Value = 'add'
        [void]$metadata.Attributes.Append($action)
        $key = $xmlDoc.CreateElement('Key', $setupComponent.NamespaceURI)
        $key.InnerText = '/IMAGE/INDEX'
        [void]$metadata.AppendChild($key)
        $value = $xmlDoc.CreateElement('Value', $setupComponent.NamespaceURI)
        $value.InnerText = [string]$InstallImageIndex
        [void]$metadata.AppendChild($value)
        [void]$installFrom.AppendChild($metadata)

        $postInstallFile = $xmlDoc.CreateElement('File', $extensions.NamespaceURI)
        $postInstallFile.SetAttribute('path', 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.ps1')
        $postInstallFile.InnerText = $postInstallScript
        [void]$extensions.AppendChild($postInstallFile)

        $firstLogonFile.InnerText = "& 'C:\Windows\Setup\Scripts\WinUtil-PostInstall.ps1';`r`n`r`n$($firstLogonFile.InnerText.Trim())"

        $null = & $Logger 'Added WinUtil post-install AppX, registry, and scheduled-task customizations to autounattend.xml.'
        return $xmlDoc.OuterXml
    }

    function Add-WinUtilISOSetupScriptFallback {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [Parameter(Mandatory)][string]$XmlContent,
            [scriptblock]$Logger
        )

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)
        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $nsMgr.AddNamespace('sg', 'https://schneegans.de/windows/unattend-generator/')

        $setupScriptsRoot = Join-Path $ContentRoot 'sources\$OEM$\$$\Setup\Scripts'
        $stagedCount = 0
        foreach ($file in $xmlDoc.SelectNodes('//sg:File', $nsMgr)) {
            $path = $file.GetAttribute('path')
            if (-not $path.StartsWith('C:\Windows\Setup\Scripts\', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $relativePath = $path.Substring('C:\Windows\Setup\Scripts\'.Length)
            $targetPath = Join-Path $setupScriptsRoot $relativePath
            New-Item -Path (Split-Path $targetPath -Parent) -ItemType Directory -Force | Out-Null

            $encoding = switch ([System.IO.Path]::GetExtension($targetPath)) {
                { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; break }
                { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true); break }
                default { [System.Text.Encoding]::Default }
            }
            $bytes = $encoding.GetPreamble() + $encoding.GetBytes($file.InnerText.Trim())
            [System.IO.File]::WriteAllBytes($targetPath, $bytes)
            $stagedCount++
        }

        $useConfigurationSet = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]/u:component[@name="Microsoft-Windows-Setup"]/u:UseConfigurationSet', $nsMgr)
        if ($useConfigurationSet) {
            $useConfigurationSet.InnerText = 'true'
            [System.IO.File]::WriteAllText((Join-Path $ContentRoot 'autounattend.xml'), $xmlDoc.OuterXml, [System.Text.UTF8Encoding]::new($false))
        }
        & $Logger "Staged $stagedCount WinUtil setup script fallback files at '$setupScriptsRoot'."
    }

    if (-not (Test-Path $ISOContentsDir)) {
        throw "ISO contents directory does not exist: $ISOContentsDir"
    }

    if ([string]::IsNullOrWhiteSpace($AutoUnattendXml)) {
        throw "autounattend.xml content is required to prepare setup media."
    }

    $preparedAutoUnattendXml = Add-WinUtilISOSetupCustomizations -XmlContent $AutoUnattendXml -InstallImageIndex $InstallImageIndex -Logger $Log
    $unattendPath = Join-Path $ISOContentsDir "autounattend.xml"
    [System.IO.File]::WriteAllText($unattendPath, $preparedAutoUnattendXml, [System.Text.UTF8Encoding]::new($false))
    & $Log "Written autounattend.xml with WinUtil setup customizations to ISO root ($unattendPath)."
    Add-WinUtilISOSetupScriptFallback -ContentRoot $ISOContentsDir -XmlContent $preparedAutoUnattendXml -Logger $Log

    Write-WinUtilISOEditionConfig -ContentRoot $ISOContentsDir -EditionId $InstallEditionId -Logger $Log

    if ($InjectCurrentSystemDrivers) {
        Add-WinUtilISOStagedDrivers -ContentRoot $ISOContentsDir -Logger $Log -InstallImagePath $InstallImagePath -InstallImageIndex $InstallImageIndex
    }
}

function Invoke-WinUtilISORefreshUSBDrives {
    $combo    = $sync["WPFWin11ISOUSBDriveComboBox"]
    $removable = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)

    $combo.Items.Clear()

    if ($removable.Count -eq 0) {
        $combo.Items.Add("未检测到 USB 驱动器。")
        $combo.SelectedIndex = 0
        $sync["Win11ISOUSBDisks"] = @()
        Write-WinUtilISOLog "未检测到 USB 驱动器。"
        return
    }

    foreach ($disk in $removable) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $combo.Items.Add("Disk $($disk.Number): $($disk.FriendlyName)  [$sizeGB GB] - $($disk.PartitionStyle)")
    }
    $combo.SelectedIndex = 0
    Write-WinUtilISOLog "找到 $($removable.Count) 个 USB 驱动器。"
    $sync["Win11ISOUSBDisks"] = $removable
}

function Invoke-WinUtilISOWriteUSB {
    $contentsDir = $sync["Win11ISOContentsDir"]
    $usbDisks    = $sync["Win11ISOUSBDisks"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show("未找到修改后的 ISO 内容。请先完成步骤 1-3。", "尚未就绪", "OK", "Warning")
        return
    }

    $installWim = Join-Path $contentsDir "sources\install.wim"
    $installEsd = Join-Path $contentsDir "sources\install.esd"
    if (Test-Path $installEsd) {
        $installEsdFile = Get-Item $installEsd
        $esdSizeBytes = $installEsdFile.Length
        $esdSizeMB = [math]::Ceiling($esdSizeBytes / 1MB)
        if ($esdSizeBytes -ge 4GB) {
            [System.Windows.MessageBox]::Show(
                "此 ISO 使用大小为 $esdSizeMB MB 的 install.esd。WinUtil 的 FAT32 USB 格式无法存储超过 4 GB 的文件。`n`n请改为导出 ISO，或使用包含 install.wim 的介质。",
                "不支持创建此 USB", "OK", "Warning")
            return
        }
    }

    $combo = $sync["WPFWin11ISOUSBDriveComboBox"]
    $selectedIndex = $combo.SelectedIndex
    $selectedItemText = [string]$combo.SelectedItem
    $usbDisks = @($usbDisks)

    $targetDisk = $null
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $usbDisks.Count) {
        $targetDisk = $usbDisks[$selectedIndex]
    } elseif ($selectedItemText -match 'Disk\s+(\d+):') {
        $selectedDiskNum = [int]$matches[1]
        $targetDisk = $usbDisks | Where-Object { $_.Number -eq $selectedDiskNum } | Select-Object -First 1
    }

    if (-not $targetDisk) {
        [System.Windows.MessageBox]::Show("请从下拉列表中选择 USB 驱动器。", "未选择驱动器", "OK", "Warning")
        return
    }

    $diskNum    = $targetDisk.Number
    $sizeGB     = [math]::Round($targetDisk.Size / 1GB, 1)

    $confirm = [System.Windows.MessageBox]::Show(
        "磁盘 $diskNum（$($targetDisk.FriendlyName)，$sizeGB GB）上的所有数据都将被永久清除。`n`n确定要继续吗？",
        "确认清除 USB", "YesNo", "Warning")

    if ($confirm -ne "Yes") {
        Write-WinUtilISOLog "用户已取消写入 USB。"
        return
    }

    $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true
    Write-WinUtilISOLog "正在开始向磁盘 $diskNum 写入 USB..."

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("diskNum",     $diskNum)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-FreeDriveLetter {
            $used = (Get-PSDrive -PSProvider FileSystem).Name
            foreach ($c in [char[]](68..90)) {
                if ($used -notcontains [string]$c) { return $c }
            }
            return $null
        }

        try {
            SetProgress "正在格式化 USB 驱动器..." 10

            # Phase 1: Clean disk via diskpart (retry once if the drive is not yet ready)
            $dpFile1 = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
            "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1 -Encoding ASCII
            Log "Running diskpart clean on Disk $diskNum..."
            $dpCleanOut = diskpart /s $dpFile1
            $dpCleanOut | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile1 -Force

            if (($dpCleanOut -join ' ') -match 'device is not ready') {
                Log "Disk $diskNum was not ready; waiting 5 seconds and retrying clean..."
                Start-Sleep -Seconds 5
                Update-Disk -Number $diskNum
                $dpFile1b = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
                "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1b -Encoding ASCII
                diskpart /s $dpFile1b | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
                Remove-Item $dpFile1b -Force
            }

            # Phase 2: Initialize as GPT
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum
            $diskObj = Get-Disk -Number $diskNum
            if ($diskObj.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum initialized as GPT."
            } else {
                Set-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum converted to GPT (was $($diskObj.PartitionStyle))."
            }

            # Phase 3: Create FAT32 partition via diskpart, then format with Format-Volume
            # (diskpart's 'format' command can fail with "no volume selected" on fresh/never-formatted drives)
            $volLabel = "W11-" + (Get-Date).ToString('yyMMdd')
            $dpFile2  = Join-Path $env:TEMP "winutil_diskpart2_$(Get-Random).txt"
            $maxFat32PartitionMB = 32768
            $diskSizeMB = [int][Math]::Floor((Get-Disk -Number $diskNum).Size / 1MB)
            $createPartitionCommand = "create partition primary"
            if ($diskSizeMB -gt $maxFat32PartitionMB) {
                $createPartitionCommand = "create partition primary size=$maxFat32PartitionMB"
                Log "Disk $diskNum is $diskSizeMB MB; creating FAT32 partition capped at $maxFat32PartitionMB MB (32 GB)."
            }

            @(
                "select disk $diskNum"
                $createPartitionCommand
                "exit"
            ) | Set-Content -Path $dpFile2 -Encoding ASCII
            Log "Creating partitions on Disk $diskNum..."
            diskpart /s $dpFile2 | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile2 -Force

            SetProgress "Formatting USB partition..." 25
            Start-Sleep -Seconds 3
            Update-Disk -Number $diskNum

            $partitions = Get-Partition -DiskNumber $diskNum
            Log "Partitions on Disk $diskNum after creation: $($partitions.Count)"
            foreach ($p in $partitions) {
                Log "  Partition $($p.PartitionNumber)  Type=$($p.Type)  Letter=$($p.DriveLetter)  Size=$([math]::Round($p.Size/1MB))MB"
            }

            $winpePart = $partitions | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $winpePart) {
                throw "Could not find the Basic partition on Disk $diskNum after creation."
            }

            # Format using Format-Volume (reliable on fresh drives; diskpart format fails
            # with 'no volume selected' when the partition has never been formatted before)
            Log "Formatting Partition $($winpePart.PartitionNumber) as FAT32 (label: $volLabel)..."
            Get-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber |
                Format-Volume -FileSystem FAT32 -NewFileSystemLabel $volLabel -Force -Confirm:$false
            Log "Partition $($winpePart.PartitionNumber) formatted as FAT32."

            SetProgress "Assigning drive letters..." 30
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum

            try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -AccessPath "$($winpePart.DriveLetter):" } catch { Log "Warning: could not remove existing partition access path: $_" }
            $usbLetter = Get-FreeDriveLetter
            if (-not $usbLetter) { throw "No free drive letters (D-Z) available to assign to the USB data partition." }
            Set-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -NewDriveLetter $usbLetter
            Log "Assigned drive letter $usbLetter to WINPE partition (Partition $($winpePart.PartitionNumber))."
            Start-Sleep -Seconds 2

            $usbDrive = "${usbLetter}:"
            $retries = 0
            while (-not (Test-Path $usbDrive) -and $retries -lt 6) {
                $retries++
                Log "Waiting for $usbDrive to become accessible (attempt $retries/6)..."
                Start-Sleep -Seconds 2
            }
            if (-not (Test-Path $usbDrive)) { throw "Drive $usbDrive is not accessible after letter assignment." }
            Log "USB data partition: $usbDrive"

            $contentSizeBytes = (Get-ChildItem -LiteralPath $contentsDir -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if (-not $contentSizeBytes) { $contentSizeBytes = 0 }
            $usbVolume = Get-Volume -DriveLetter $usbLetter
            $partitionCapacityBytes = [int64]$usbVolume.Size
            $partitionFreeBytes = [int64]$usbVolume.SizeRemaining

            $contentSizeGB = [math]::Round($contentSizeBytes / 1GB, 2)
            $partitionCapacityGB = [math]::Round($partitionCapacityBytes / 1GB, 2)
            $partitionFreeGB = [math]::Round($partitionFreeBytes / 1GB, 2)

            Log "Source content size: $contentSizeGB GB. USB partition capacity: $partitionCapacityGB GB, free: $partitionFreeGB GB."

            if ($contentSizeBytes -gt $partitionCapacityBytes) {
                throw "ISO content ($contentSizeGB GB) is larger than the USB partition capacity ($partitionCapacityGB GB). Use a larger USB drive or reduce image size."
            }

            if ($contentSizeBytes -gt $partitionFreeBytes) {
                throw "Insufficient free space on USB partition. Required: $contentSizeGB GB, available: $partitionFreeGB GB."
            }

            SetProgress "正在把 Windows 11 文件复制到 USB..." 45

            # Copy files; split install.wim if > 4 GB (FAT32 limit)
            $installWim = Join-Path $contentsDir "sources\install.wim"
            if (Test-Path $installWim) {
                $wimSizeMB = [math]::Round((Get-Item $installWim).Length / 1MB)
                if ($wimSizeMB -gt 3800) {
                    Log "install.wim is $wimSizeMB MB - splitting for FAT32 compatibility... This will take several minutes."
                    $splitDest = Join-Path $usbDrive "sources\install.swm"
                    New-Item -ItemType Directory -Path (Split-Path $splitDest) -Force
                    Split-WindowsImage -ImagePath $installWim -SplitImagePath $splitDest -FileSize 3800 -CheckIntegrity
                    Log "install.wim split complete."
                    Log "Copying remaining files to USB..."
                    & robocopy $contentsDir $usbDrive /E /XF install.wim /NFL /NDL /NJH /NJS
                } else {
                    & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
                }
            } else {
                & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
            }

            SetProgress "正在完成 USB 驱动器设置..." 90
            Log "文件已复制到 USB。"
            SetProgress "USB 写入完成" 100
            Log "USB 驱动器已可使用。"

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "USB 驱动器创建成功！`n`n现在可以从该驱动器启动并安装 Windows 11。",
                    "USB 已就绪", "OK", "Info")
            })
        } catch {
            Log "写入 USB 时出错：$_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("USB 写入失败：`n`n$_", "USB 写入错误", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

# [功能说明] Invoke-WinUtilScript：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Write-WinUtilLog -Component "Script" -Message "Running script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
        Write-WinUtilLog -Component "Script" -Message "Completed script for $Name"
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Command not found while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Runtime exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Security exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Access denied while running script for $Name`: $($PSItem.Exception.Message)"
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Unhandled exception while running script for $Name`: $($psitem.Exception.Message)"
    }

}

# [功能说明] Invoke-WinUtilSponsors：脚本内部函数（用于组织代码与复用逻辑）。

Function Invoke-WinUtilSponsors {
    $sponsors = ([regex]::Matches(([regex]::Match((Invoke-RestMethod https://github.com/sponsors/ChrisTitusTech),'(?s)(?<=Current sponsors).*?(?=Past sponsors)')).Value,'(?<=alt="@)[^"]+')).Value | Where-Object {$_ -ne "ChrisTitusTech"}
    return $sponsors
}

# [功能说明] Invoke-WinUtilSSHServer：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server... This will take a long time."
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "Starting the services"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$Home\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    }

    Write-Host "Configuring sshd_config for standard authorized_keys behavior..."
    $sshdConfigPath = "C:\ProgramData\ssh\sshd_config"

    $configContent = Get-Content -Path $sshdConfigPath -Raw

    $updatedContent = $configContent -replace '(?m)^(Match Group administrators)$', '# $1'
    $updatedContent = $updatedContent -replace '(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '# $1'

    if ($updatedContent -ne $configContent) {
        Set-Content -Path $sshdConfigPath -Value $updatedContent -Force
        Write-Host "Commented out administrator-specific SSH key configuration in sshd_config"
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config"
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}

# [功能说明] Invoke-WinutilThemeChange：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    # [功能说明] Set-WinutilTheme：设置系统/脚本状态或写入配置（可能涉及注册表、策略、UI 状态）。

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        # [功能说明] Set-ThemeResourceProperty：设置系统/脚本状态或写入配置（可能涉及注册表、策略、UI 状态）。

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($themeProperty in $themeProperties) {
            # Apply properties that deal with colors
            if ($themeProperty.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($themeProperty.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($themeProperty.Name)" -Value $themeProperty.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($themeProperty.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($themeProperty.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($themeProperty.Name -like "*Thickness*") -or ($themeProperty.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($themeProperty.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Reapply font scaling if it was previously set (theme change resets shared resources)
    if ($sync.ContainsKey("FontScaleFactor") -and $sync.FontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScaleFactor
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}

# [功能说明] Invoke-WinUtilTweaks：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    $action = if ($undo) { "Undo" } else { "Apply" }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak: $CheckBox"

    if ($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if ($sync.configs.tweaks.$CheckBox.service) {
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if ($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if ($changeservice) {
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if ($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if ($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if (!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Remove-WinUtilAPPX -Name $psitem
            }
            Remove-WinUtilProvisionedAPPX -PackageList $sync.configs.tweaks.$CheckBox.appx
        }
    }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak completed: $CheckBox"
}

# [功能说明] Invoke-WinUtilUninstallPSProfile：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WinUtilUninstallPSProfile {

    if (Test-Path ($Profile + ".bak")) {
        Move-Item -Path ($Profile + ".bak") -Destination $Profile
    } else {
        Remove-Item -Path $Profile
    }

    Write-Host "Successfully uninstalled CTT PowerShell Profile." -ForegroundColor Green
}

# [功能说明] Remove-WinUtilAPPX：移除/清理相关内容（常见为注册表值、文件夹、Windows 组件/包等）。

function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX package pattern: $Name"

    # We explicitly loop through packages instead of using the pipeline because PowerShell 7 pipeline binding
    # for Remove-AppxPackage fails silently, and Get-AppxPackage -AllUsers returns duplicate objects for each user profile.
    $pkgs = Get-AppxPackage "*$Name*" -AllUsers | Sort-Object -Property PackageFullName -Unique
    if ($null -ne $pkgs) {
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX removal completed for package pattern: $Name"
}

# [功能说明] Remove-WinUtilProvisionedAPPX：移除所选预配 AppX 软件包。

function Remove-WinUtilProvisionedAPPX {
    <#

    .SYNOPSIS
        Removes all AppX provisioned packages that match the given names

    .PARAMETER PackageList
        An array of names of the APPX packages to remove

    .EXAMPLE
        Remove-WinUtilProvisionedAPPX -PackageList @("Microsoft.Microsoft3DViewer", "Microsoft.WindowsCalculator")

    #>
    param (
        [string[]]$PackageList
    )

    if ($null -eq $PackageList -or $PackageList.Count -eq 0) {
        return
    }

    Write-Host "`nRemoving provisioned packages..."
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX provisioned packages: $($PackageList -join ', ')"

    # DISM cmdlets like Get-AppxProvisionedPackage often fail with "Class not registered" or hang in PowerShell 7.
    # We shell out to Windows PowerShell 5.1 (powershell.exe) to reliably remove the provisioned packages.
    $ps5Command = {
        $pkgs = $args
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($Package in $pkgs) {
            $provs = $provisionedPackages |
                Where-Object DisplayName -Like "*$Package*"

            if ($null -ne $provs) {
                foreach ($prov in $provs) {
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                    }
                    catch {
                        $failures.Add("Failed to remove provisioned AppX package $($prov.PackageName): $($_.Exception.Message)")
                    }
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    $removalOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $PackageList 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -ne $removalOutput) {
        $failureDetails = ($removalOutput | Out-String).Trim()
        $errorMessage = "AppX provisioned package removal failed: $failureDetails"
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX provisioned package removal completed."
}

function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )
    $selectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures + $sync.selectedAppx), [StringComparer]::OrdinalIgnoreCase)

    foreach ($syncEntry in $sync.GetEnumerator()) {
        if ($syncEntry.Value -is [System.Windows.Controls.CheckBox] -and $syncEntry.Name -notlike "WPFToggle*" -and $syncEntry.Name -like $checkboxfilterpattern) {
            $checkboxName = $syncEntry.Key
            $sync.$checkboxName.IsChecked = $selectedSet.Contains($checkboxName)
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "已选应用：$count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = [System.Collections.Generic.HashSet[string]]::new([string[]]@($sync.selectedToggles), [StringComparer]::OrdinalIgnoreCase)
        foreach ($toggle in $sync.GetEnumerator()) {
            if ($toggle.Key -like "WPFToggle*" -and $toggle.Value -is [System.Windows.Controls.CheckBox] -and $importedToggles.Contains($toggle.Key)) {
                $sync[$toggle.Key].IsChecked = $true
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}

# [功能说明] Save-WinUtilFile：通过保存对话框写出配置或生成结果。

function Save-WinUtilFile {
    <#
    .SYNOPSIS
        Downloads a file and reports transfer progress.
    #>
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [scriptblock]$ProgressCallback
    )

    $response = $null
    $responseStream = $null
    $outputStream = $null

    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $responseStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($DestinationPath)
        $buffer = New-Object byte[] 81920
        $downloadedBytes = 0L
        $lastPercent = -1

        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloadedBytes / $totalBytes) * 100))
                if ($percent -ne $lastPercent) {
                    & $ProgressCallback $percent
                    $lastPercent = $percent
                }
            }
        }

        if ($lastPercent -ne 100) {
            & $ProgressCallback 100
        }
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $responseStream) {
            $responseStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

# [功能说明] Set-WinUtilAppCategoryFilter：按所选分类筛选安装页面的软件列表。

function Set-WinUtilAppCategoryFilter {
    <#
        .SYNOPSIS
            Applies an exact application category filter from an Install tab search chip.

        .PARAMETER Category
            The application category to show. An empty value clears the filter.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Category = ""
    )

    $sync.SearchBar.Tag = $Category
    $sync.SearchBar.Text = $Category
    Find-AppsByNameOrDescription -SearchString $Category -Category $Category
}

# [功能说明] Set-WinUtilDNS：设置系统/脚本状态或写入配置（可能涉及注册表、策略、UI 状态）。

function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)

    if($DNSProvider -eq "Default") {
        Write-WinUtilLog -Component "DNS" -Message "DNS provider is Default; no DNS changes applied."
        return
    }

    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)
        Write-WinUtilLog -Component "DNS" -Message "Setting DNS provider to $DNSProvider for $(@($Adapters).Count) active adapter(s)."

        if($DNSProvider -ne "DHCP") {
            $dns = $sync.configs.dns.$DNSProvider
            if($null -eq $dns) {
                Write-Warning "DNS provider $DNSProvider was not found in configuration."
                Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not found in configuration."
                return
            }
        }

        $dohSupported = [bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
        $dnscacheBase = "HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters"

        Foreach ($Adapter in $Adapters) {
            $interfaceParams = "$dnscacheBase\$($Adapter.InterfaceGuid)"

            if($DNSProvider -eq "DHCP") {
                Write-WinUtilLog -Component "DNS" -Message "Resetting DNS to DHCP on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex))."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
                netsh interface ip set dnsservers name="$($Adapter.Name)" source=dhcp
                netsh interface ipv6 set dnsservers name="$($Adapter.Name)" source=dhcp

                $dohInterfaceSettings = "$interfaceParams\DohInterfaceSettings"
                if (Test-Path $dohInterfaceSettings) {
                    if ($dohSupported) {
                        $dohServerAddresses = @(
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh" -ErrorAction SilentlyContinue
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh6" -ErrorAction SilentlyContinue
                        ) | Select-Object -ExpandProperty PSChildName -Unique

                        foreach ($ip in $dohServerAddresses) {
                            if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
                                Write-WinUtilLog -Component "DNS" -Message "Removing DoH registration for $ip."
                                Remove-DnsClientDohServerAddress -ServerAddress $ip -Confirm:$false -ErrorAction Stop
                            }
                        }
                    }

                    Remove-Item -Path $dohInterfaceSettings -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv4 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary), $($dns.Secondary)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary, $dns.Secondary)
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv6 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary6), $($dns.Secondary6)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary6, $dns.Secondary6)

                if ($dohSupported -and $dns.DohTemplate) {
                    $ips = @($dns.Primary, $dns.Secondary, $dns.Primary6, $dns.Secondary6) | Where-Object { $_ }
                    foreach ($ip in $ips) {
                        $existing = Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue
                        if ($existing) {
                            Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dns.DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                        } else {
                            Write-WinUtilLog -Component "DNS" -Message "Registering DoH template for $ip."
                            Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dns.DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                        }

                        $leaf = if ($ip.Contains(':')) { 'Doh6' } else { 'Doh' }
                        $regPath = "$interfaceParams\DohInterfaceSettings\$leaf\$ip"

                        if (-not (Test-Path $regPath)) {
                            New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
                        }
                        New-ItemProperty -Path $regPath -Name "DohFlags" -Value 1 -PropertyType QWord -Force -ErrorAction Stop | Out-Null
                    }
                }
            }
        }
        if ($DNSProvider -ne "DHCP" -and $dohSupported -and $dns.DohTemplate) {
            Clear-DnsClientCache
        }
        Write-WinUtilLog -Component "DNS" -Message "DNS provider change completed: $DNSProvider"
    } catch {
        Write-Warning "DNS provider $DNSProvider was not completed because an error occurred."
        Write-Warning $psitem.Exception.Message
        Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not completed: $($psitem.Exception.Message)"
    }
}

# [功能说明] Set-WinUtilRegistry：设置系统/脚本状态或写入配置（可能涉及注册表、策略、UI 状态）。

function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            Write-WinUtilLog -Component "Registry" -Message "Creating registry path: $Path"
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Write-WinUtilLog -Component "Registry" -Message "Setting $Path\$Name ($Type) to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Write-WinUtilLog -Component "Registry" -Message "Removing $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Security exception while changing $Path\$Name to $Value`: $($psitem.Exception.Message)"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Registry item not found while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
       Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unauthorized while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unhandled exception while changing $Path\$Name`: $($psitem.Exception.Message)"
    }
}

# [功能说明] Set-WinUtilService：设置系统/脚本状态或写入配置（可能涉及注册表、策略、UI 状态）。

Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"
        Write-WinUtilLog -Component "Service" -Message "Setting service $Name startup type to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        if (($service.PSObject.Properties.Name -contains "StartType") -and ([string]$service.StartType -eq [string]$StartupType) ) {
            Write-Host "Service $Name is already set to $StartupType"
            Write-WinUtilLog -Component "Service" -Message "Service $Name startup type is already $StartupType; no change needed."
            return
        }

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
        Write-WinUtilLog -Component "Service" -Message "Service $Name startup type set to $StartupType"
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Warning "Service $Name was not found."
            Write-WinUtilLog -Level "WARN" -Component "Service" -Message "Service $Name was not found."
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception."
            Write-Warning $_.Exception.Message
            Write-WinUtilLog -Level "ERROR" -Component "Service" -Message "Unable to set service $Name to $StartupType`: $($_.Exception.Message)"
        }
    }

}

# [功能说明] Set-WinUtilTaskbaritem：设置系统/脚本状态或写入配置（可能涉及注册表、策略、UI 状态）。

function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                if (-not $sync["logorender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                if (-not $sync["checkmarkrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                if (-not $sync["warningrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}

function Set-WinUtilTweaksProgressIndicator {
    <#
    .SYNOPSIS
        Shows, updates, or hides the window-level progress indicator used by long-running
        workflows such as app management, Tweaks, AppX management, and Win11 Creator.
        It lives outside the TabControl, so it stays visible no matter which tab is active.
    .PARAMETER Visible
        Whether the indicator should be shown or hidden.
    .PARAMETER Label
        The text to display above the progress bar.
    .PARAMETER Percent
        The percentage of the progress bar that should be filled (0-100).
    #>
    param(
        [bool]$Visible,
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    $indicatorVisible = if ($Visible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $indicatorLabel = $Label
    $hasLabel = $PSBoundParameters.ContainsKey('Label')
    $hasPercent = $PSBoundParameters.ContainsKey('Percent')

    Invoke-WPFUIThread -ScriptBlock {
        $sync.WPFTweaksProgressBar.Visibility = $indicatorVisible
        if ($hasLabel) {
            $sync.WPFTweaksProgressLabel.Text = $indicatorLabel
        }
        if ($hasPercent) {
            $sync.WPFTweaksProgressValue.Value = $Percent
        }
    }
}

# [功能说明] Show-CustomDialog：脚本内部函数（用于组织代码与复用逻辑）。

function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "WinUtil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0
    $linkHoverBrush = $LinkHoverForegroundColor

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            Start-Process $eventSender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $linkHoverBrush
            $eventSender.FontSize = ($FontSize + ($FontSize / 4))
            $eventSender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $LinkForegroundColor
            $eventSender.FontSize = $FontSize
            $eventSender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}

# [功能说明] Show-WinUtilMessage：显示统一样式的 WinUtil 提示消息。

function Show-WinUtilMessage {
    <#
    .SYNOPSIS
        Shows a WinUtil message box and returns the selected result.
    #>
    param (
        [string]$Message,
        [string]$Title = "Winutil",
        $Button = "OK",
        $Icon = "Information"
    )

    [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
}

function Invoke-WinUtilInstallAppRenderBatch {
    param(
        [Parameter(Mandatory = $true)]
        $CategoryBatch
    )

    foreach ($appKey in $CategoryBatch.AppKeys) {
        $sync.$appKey = Initialize-InstallAppEntry -TargetElement $CategoryBatch.TargetElement -AppKey $appKey
    }

    if ($sync.currentTab -eq "Install" -and $sync.SearchBar -and -not [string]::IsNullOrWhiteSpace($sync.SearchBar.Text)) {
        Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Category $sync.SearchBar.Tag
    }
}

function Complete-WinUtilInstallAppRendering {
    $sync.InstallAppEntriesRendered = $true
}

function Invoke-WinUtilInstallAppRenderNextBatch {
    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    Complete-WinUtilInstallAppRendering
}

function Start-WinUtilInstallAppRendering {
    if ($null -eq $sync.InstallAppRenderQueue) {
        return
    }

    $sync.InstallAppEntriesRendered = $false

    if ($sync.Form -and $sync.Form.Dispatcher) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    while ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    Complete-WinUtilInstallAppRendering
}

# [功能说明] Test-WinUtilPackageManager：环境/输入检测（例如：镜像兼容性、依赖是否存在、路径是否有效）。

function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        WinGet is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}

function Update-WinUtilSelections ($flatJson) {
    foreach ($cbkey in $flatJson) {

        $listName = switch -Regex ($cbkey) {
            '^WPFInstall' { 'selectedApps' }
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
            '^WPFFeature' { 'selectedFeatures' }
            '^WPFAppx'    { 'selectedAppx' }
        }

        $sync.$listName.Add($cbkey)
    }
}

# [功能说明] Write-WinUtilLog：记录运行状态并更新可见日志。

function Write-WinUtilLog {
    <#

    .SYNOPSIS
        Writes a timestamped WinUtil log entry to the active session log.

    .PARAMETER Message
        The message to write.

    .PARAMETER Level
        The severity level for the log entry.

    .PARAMETER Component
        The WinUtil component producing the log entry.

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$Component = "WinUtil"
    )

    try {
        $logPath = $null
        $transcriptPath = $null
        if ($null -ne $sync -and $sync.ContainsKey("logPath")) {
            $logPath = $sync.logPath
        }

        if ($null -ne $sync -and $sync.ContainsKey("transcriptPath")) {
            $transcriptPath = $sync.transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($transcriptPath)) {
            $logPath = $transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and $null -ne $sync -and $sync.ContainsKey("winutildir")) {
            $logDirectory = Join-Path $sync.winutildir "logs"
            $logPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            $sync.logPath = $logPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
            if ([string]::IsNullOrWhiteSpace($script:WinUtilLogPath)) {
                $logDirectory = Join-Path (Join-Path $env:LocalAppData "winutil") "logs"
                $script:WinUtilLogPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            }
            $logPath = $script:WinUtilLogPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath)) {
            return
        }

        $logDirectory = Split-Path -Path $logPath -Parent
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $line = "[$timestamp] [$Level] [$Component] $Message"

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and $logPath -eq $transcriptPath) {
            Write-Host $line
            return
        }

        try {
            Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch [System.IO.IOException] {
            Write-Host $line
        }
    } catch {
        Write-Warning "Unable to write WinUtil log entry: $($_.Exception.Message)"
    }
}

# [功能说明] Initialize-WPFUI：脚本内部函数（用于组织代码与复用逻辑）。

function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "安装或升级 $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "卸载 $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "用默认浏览器打开应用官网`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}


function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Milliseconds 100
        while ($sync.ProcessRunning) {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($sync.selectedTweaks.Count -gt 0) {
        Write-Host "Applying tweaks..."
        Invoke-WPFtweaksbutton
        BusyWait
    }

    if ($sync.selectedFeatures.Count -gt 0) {
        Write-Host "Applying features..."
        Invoke-WPFFeatureInstall
        BusyWait
    }

    if ($sync.selectedApps.Count -gt 0) {
        Write-Host "Installing applications..."
        Invoke-WPFInstall
        BusyWait
    }

    if ($sync.selectedAppx.Count -gt 0) {
        Write-Host "Removing AppX packages..."
        Invoke-WPFAppxRemoval
        BusyWait
    }

    Write-Host "Done."
}

# [功能说明] Invoke-WPFAppxInstall：安装 AppX 页面中选中的软件包。

function Invoke-WPFAppxInstall {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "已有 AppX 任务正在运行。" -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "未选择 AppX 软件包" -Title "错误" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX install for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在准备安装 AppX（0/$totalPackages）" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 100)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在安装 $($app.Content)（$position/$totalPackages）" -Percent $startPercent
                }
                Write-Host "Installing $($app.Content)"
                Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId

                $completedPercent = [int](($position / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "已安装 $($app.Content)（$position/$totalPackages）" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            Write-Host "================================="
            Write-Host "--   AppX Install Finished   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX install finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX 安装完成" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX install failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX 安装失败" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

# [功能说明] Invoke-WPFAppxRemoval：移除 AppX 页面中选中的软件包。

function Invoke-WPFAppxRemoval {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "已有 AppX 任务正在运行。" -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "未选择 AppX 软件包" -Title "错误" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        $packageList = [System.Collections.Generic.List[string]]::new()

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX removal for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在准备移除 AppX（0/$totalPackages）" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在移除 $($app.Content)（$position/$totalPackages）" -Percent $startPercent
                }

                if ($key -eq "WPFAppxMicrosoft_XboxGamingOverlay") {
                    # Making sure Game Bar isn't running
                    Write-WinUtilLog -Component "AppX" -Message "Stopping GameBarFTServer before removing Xbox Gaming Overlay."
                    Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue

                    # This stops annoying ms-gamebar popup when launching games.
                    Write-WinUtilLog -Component "AppX" -Message "Disabling Game DVR capture before removing Xbox Gaming Overlay."
                    Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0
                }

                if ($key -eq "WPFAppxMicrosoft_WindowsNotepad") {
                    Write-WinUtilLog -Component "AppX" -Message "Stopping dllhost before removing Notepad."
                    Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue
                }

                Write-Host "Removing $($app.Content)"
                Write-WinUtilLog -Component "AppX" -Message "Removing $($app.Content) ($($app.PackageId))."
                Remove-WinUtilAPPX -Name $app.PackageId
                $packageList.Add($app.PackageId)

                if ($key -eq "WPFAppxMSTeams") {
                    # Uninstalls Microsoft Teams Meeting Add-in for Microsoft Office
                    Write-WinUtilLog -Component "AppX" -Message "Uninstalling Microsoft Teams meeting add-in package."
                    Get-Package -Name "Microsoft Teams*" -ErrorAction SilentlyContinue | Uninstall-Package -Force
                }

                $completedPercent = [int](($position / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "已移除 $($app.Content)（$position/$totalPackages）" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if ($packageList.Count -gt 0) {
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在移除预配的 AppX 软件包" -Percent 90
                }
                Remove-WinUtilProvisionedAPPX -PackageList $packageList.ToArray()
            }

            Write-Host "================================="
            Write-Host "--   AppX Removal Finished   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX removal finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX 移除完成" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX removal failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX 移除失败" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }

    }
}

# [功能说明] Invoke-WPFButton：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Chris Titus Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning -and -not $sync.Win11ISOProcessRunning) {
        Set-WinUtilTweaksProgressIndicator -Visible $false
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFAdvanced" {Invoke-WPFPresets "Advanced" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Enable}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFAppxRemoval" {Invoke-WPFTab "WPFTab6BT"}
        "WPFBackToTweaks" {Invoke-WPFTab "WPFTab2BT"}
        "WPFInstallSelectedAppx" {Invoke-WPFAppxInstall}
        "WPFRemoveSelectedAppx" {Invoke-WPFAppxRemoval}
        "WPFDefaultAppxSelection" {Invoke-WPFPresets "AppxDefault" -checkboxfilterpattern "WPFAppx*"}
        "WPFSelectAllAppx" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $true}
        }
        "WPFClearAppxSelection" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $false}
        }
        "WPFGetInstalledAppx" {
            $installedAppxPackages = Get-WinUtilInstalledAPPX
            foreach ($appx in $sync.configs.appxHashtable.GetEnumerator()) {
                if ($appx.Value.PackageId -in $installedAppxPackages) {
                    $sync.$($appx.Key).IsChecked = $true
                }
            }
        }
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
        "WPFMinimizeButton" {[Windows.SystemCommands]::MinimizeWindow($sync.Form)}
        "WPFMaximizeButton" {
            if ($sync.Form.WindowState -eq [Windows.WindowState]::Normal) {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            } else {
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            }
        }
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
    }
}

# [功能说明] Invoke-WPFFeatureInstall：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "功能安装任务正在运行。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$Features.Count) }
        }

        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}

# [功能说明] Invoke-WPFFixesNetwork：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFFixesNetwork {
    netsh winsock reset
    netsh int ip reset
    Write-Host "Network Configuration has been Reset. Please restart your computer."
}

function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync

    Write-Host "================================="
    Write-Host "-- NTP Configuration Complete ---"
    Write-Host "================================="
}

# [功能说明] Invoke-WPFFixesUpdate：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "重置 Windows 更新"
    $Messageboxbody = ("默认设置已加载。`n请重启电脑。")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}

# [功能说明] Invoke-WPFFixesWinget：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}

# [功能说明] Invoke-WPFGetInstalled：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFGetInstalled {
    <#
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "安装任务正在运行，暂时无法获取已安装项目。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager
    $operation = [Hashtable]::Synchronized(@{
        Checkboxes = @()
        Error = $null
    })
    $completeAction = [Action[hashtable, string]]{
        param(
            [hashtable]$completedOperation,
            [string]$completedCheckbox
        )
        try {
            if ($completedOperation.Error) {
                Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Get installed state failed: $($completedOperation.Error)"
                Write-Warning "Unable to get installed state: $($completedOperation.Error)"
                return
            }

            if ($completedCheckbox -eq "winget") {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    if (-not $sync.selectedApps.Contains($checkboxName)) {
                        $sync.selectedApps.Add($checkboxName)
                    }
                }
                Reset-WPFCheckBoxes -checkboxfilterpattern "WPFInstall*"
            } else {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    $sync.$checkboxName.ischecked = $True
                }
            }
        } finally {
            $sync.ProcessRunning = $false
            Set-WinUtilTaskbaritem -state "None"
        }
    }

    $sync.ProcessRunning = $true
    Set-WinUtilTaskbaritem -state "Indeterminate"
    try {
        Invoke-WPFRunspace -ParameterList @(
            ("managerPreference", $managerPreference),
            ("checkbox", $checkbox),
            ("operation", $operation),
            ("completeAction", $completeAction)
        ) -ScriptBlock {
            param (
                [string]$checkbox,
                [string]$managerPreference,
                [hashtable]$operation,
                [Action[hashtable, string]]$completeAction
            )
            try {
                if ($checkbox -eq "winget") {
                    switch ($managerPreference) {
                        "Choco" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox "choco"); break }
                        "Winget" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox); break }
                    }
                } elseif ($checkbox -eq "tweaks") {
                    $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox)
                }
            } catch {
                $operation.Error = $_.Exception.Message
            } finally {
                $sync.Form.Dispatcher.BeginInvoke($completeAction, [object[]]@($operation, $checkbox)) | Out-Null
            }
        }
    } catch {
        $operation.Error = $_.Exception.Message
        $completeAction.Invoke($operation, $checkbox)
    }
}

# [功能说明] Invoke-WPFImpex：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    # [功能说明] ConfigDialog：脚本内部函数（用于组织代码与复用逻辑）。

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures + $sync.selectedAppx) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "没有可导出的设置。请至少选择一个应用、优化、开关、功能或 AppX 软件包。",
                            "没有可导出的内容", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://christitus.com/win) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "所选文件不包含可导入的设置，未进行任何更改。",
                            "配置为空", "OK", "Warning")
                        return
                    }

                    # Clear all existing selections before importing so the import replaces
                    # the current state rather than merging with it
                    $sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedApps = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()

                    Update-WinUtilSelections -flatJson $flattenedJson

                    if ($sync.Form) {
                        Reset-WPFCheckBoxes -doToggles $true
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}

# [功能说明] Invoke-WPFInstall：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [PSObject[]]$PackagesToInstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )


    if($sync.ProcessRunning) {
        $msg = "已有安装任务正在运行。"
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "请选择要安装或升级的程序。"
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Install" -Message "Install requested for $(@($PackagesToInstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToInstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Install" -Message "Install selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        Write-WinUtilLog -Component "Install" -Message "Install package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Install-WinUtilWinget
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    Install-WinUtilProgramWinget -Action Install -Programs @($program)
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Install workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }
    }
}

# [功能说明] Invoke-WPFInstallUpgrade：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList '-NoExit winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
    }
}

# [功能说明] Invoke-WPFOOSU：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFOOSU {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "已有其他任务正在运行。" -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $downloadPath = Join-Path $sync.winutildir "ooshutup10.exe"
    $sync.ProcessRunning = $true

    Invoke-WPFRunspace -ParameterList @(,("downloadPath", $downloadPath)) -ScriptBlock {
        param($downloadPath)

        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "OOSU" -Message "Downloading O&O ShutUp10++."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ (0%)" -Percent 0
            }

            Save-WinUtilFile -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -DestinationPath $downloadPath -ProgressCallback {
                param($percent)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ ($percent%)" -Percent $percent
                }
            }

            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Launching O&O ShutUp10++" -Percent 100
            }
            Start-Process -FilePath $downloadPath

            Write-WinUtilLog -Component "OOSU" -Message "O&O ShutUp10++ launched."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ launched" -Percent 100
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "OOSU" -Message "O&O ShutUp10++ download failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ download failed" -Percent 100
            }
            Write-Error "Couldn't download O&O ShutUp10. Please make sure you have an active Internet connection."
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

# [功能说明] Invoke-WPFPanelAutologin：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFPanelAutologin {
    Invoke-WebRequest -Uri https://live.sysinternals.com/Autologon.exe -OutFile "$winutildir\autologin.exe"
    Start-Process -FilePath "$winutildir\autologin.exe" -ArgumentList /accepteula
}

# [功能说明] Invoke-WPFPopup：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}

# [功能说明] Invoke-WPFPresets：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFAppx*" { $sync.selectedAppx = [System.Collections.Generic.List[string]]::new() }
        "WPFFeature*" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle*" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}

# [功能说明] Invoke-WPFRunspace：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    [OutputType([System.IAsyncResult])]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    if (-not ("WinUtilRunspaceCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class WinUtilRunspaceCleanupState
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilRunspaceCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilRunspaceCleanupState;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
        }
    }
}
"@
    }

    Initialize-WinUtilRunspacePool | Out-Null

    # Create a PowerShell instance
    $powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    [void]$powershell.AddScript($ScriptBlock)
    [void]$powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        [void]$powershell.AddParameter($parameter[0], $parameter[1])
    }

    $powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $handle = $powershell.BeginInvoke()

    $cleanupState = [WinUtilRunspaceCleanupState]::new()
    $cleanupState.PowerShell = $powershell
    $cleanupState.Handle = $handle
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject($handle.AsyncWaitHandle, [WinUtilRunspaceCleanup]::Callback, $cleanupState, -1, $true) | Out-Null

    # Return the handle
    return $handle
}

function Invoke-WPFSelectedCheckboxesUpdate ($type, $checkboxName) {
    $listName = switch -Regex ($checkboxName) {
        '^WPFInstall' { 'selectedApps' }
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
        '^WPFFeature' { 'selectedFeatures' }
        '^WPFAppx'    { 'selectedAppx' }
    }

    $selectionChanged = $false
    if ($type -eq "Add") {
        if (-not $sync.$listName.Contains($checkboxName)) {
            $sync.$listName.Add($checkboxName)
            $selectionChanged = $true
        }
    } else {
        $selectionChanged = $sync.$listName.Remove($checkboxName)
    }

    if ($listName -eq "selectedApps" -and $selectionChanged) {
        $sync.WPFselectedAppsButton.Content = "已选应用：$($sync.selectedApps.Count)"
        $sync.selectedAppsstackPanel.Children.Clear()
        $sync.selectedApps | Sort-Object | ForEach-Object {
            Add-SelectedAppsMenuItem -name $sync.configs.applicationsHashtable.$_.Content -key $_
        }
    }
}

# [功能说明] Invoke-WPFSSHServer：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}

# [功能说明] Invoke-WPFSystemRepair：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}

# [功能说明] Invoke-WPFTab：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    $sync.$tabNav.Items[$tabNumber].IsSelected = $true
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header
    Initialize-WinUtilTabContent -TabName $sync.currentTab

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Tweaks") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "AppX") {
        # Reset AppX tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Show search bar in Install, Tweaks, and AppX tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 1 -or $tabNumber -eq 5) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}

function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}

# [功能说明] Invoke-WPFtweaksbutton：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "已有任务正在运行，暂时无法执行优化。"
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0
  Write-WinUtilLog -Component "Tweaks" -Message "Tweaks requested: $(@($Tweaks).Count) selected tweak(s), DNS provider: $dnsProvider"

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "请勾选要执行的优化。"
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Creating restore point" -Percent 0
    Write-WinUtilLog -Component "Tweaks" -Message "Creating restore point before applying selected tweaks."
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "================================="
      Write-Host "--     Tweaks are Finished    ---"
      Write-Host "================================="
      Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed after restore point."
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    if ($dnsProvider -ne "Default") {
      Set-WinUtilDNS -DNSProvider $dnsProvider
    }

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Applying $($tweaks[$i]) ($($completedSteps + 1)/$totalSteps)" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed."
  }
}

# [功能说明] Invoke-WPFUIElements：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                            # Skip applying tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtilTweaks $Sender.name
                            }
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                            # Skip undoing tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            }
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $toggleButton.Name) {
                            $toggleButton.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($toggleButton.Name) | Out-Null
                        }
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $button.Name) {
                            $button.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($button.Name) | Out-Null
                        }
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)
                            $radioButtonGroups[$entryInfo.GroupName] = $groupStackPanel

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    "Note" {
                        $textBlock = New-Object Windows.Controls.TextBlock
                        $textBlock.TextWrapping = "Wrap"
                        $textBlock.Margin = "5,5,5,5"
                        $textBlock.UseLayoutRounding = $true

                        $bulletRun = New-Object Windows.Documents.Run
                        $bulletRun.Text = [char]0x25CF
                        $bulletRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(110, 255, 114))
                        $bulletRun.FontSize = 11.5

                        $textRun = New-Object Windows.Documents.Run
                        $textRun.Text = " $($entryInfo.Content)"
                        $textRun.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $textRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))

                        $textBlock.Inlines.Add($bulletRun)
                        $textBlock.Inlines.Add($textRun)

                        $itemsControl.Items.Add($textBlock) | Out-Null
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $checkBox

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Start-Process $Sender.ToolTip -ErrorAction Stop
                            })

                            $updateLinkMargin = {
                                [System.Object]$Sender = $args[0]
                                $linkedCheckBox = $Sender.Tag
                                $MarginTopBase = if ($linkedCheckBox) { $linkedCheckBox.Margin.Top } else { 0 }
                                $Sender.Margin = New-Object Windows.Thickness(
                                    [math]::Round($Sender.FontSize * 0.5),
                                    ($MarginTopBase - [math]::Round($Sender.FontSize / 2)),
                                    0, 0
                                )
                            }
                            $textBlock.Add_Loaded($updateLinkMargin)
                            $fontSizeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
                                [Windows.Controls.Control]::FontSizeProperty,
                                [Windows.Controls.TextBlock]
                            )
                            $fontSizeDescriptor.AddValueChanged($textBlock, $updateLinkMargin)

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                        })
                    }
                }
            }
        }
    }
}

function Invoke-WPFUIThread ($ScriptBlock) {
    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}

# [功能说明] Invoke-WPFUltimatePerformance：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFUltimatePerformance ([switch]$Enable) {
    if ($Enable) {
        powercfg /setactive (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Select-String -Pattern '[A-Fa-f0-9-]{36}').Matches.Value
        [System.Windows.MessageBox]::Show("“卓越性能”电源计划已安装并启用。","成功","OK","Information")
    } else {
        powercfg /restoredefaultschemes
        [System.Windows.MessageBox]::Show("电源计划已恢复默认设置。","成功","OK","Information")
    }
}

# [功能说明] Invoke-WPFundoall：回滚/撤销之前应用的更改（按所选项恢复相关设置）。

function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "已有任务正在运行，暂时无法撤销优化。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "请勾选要撤销的优化。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks requested: $(@($tweaks).Count) selected tweak(s)."
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在撤销 $($tweaks[$i])（$($i + 1)/$($tweaks.Count)）" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "撤销优化完成" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks workflow completed."

    }
}

# [功能说明] Invoke-WPFUnInstall：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "已有安装或卸载任务正在运行。"
        Show-WinUtilMessage -Message $msg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "请选择要卸载的程序。"
        Show-WinUtilMessage -Message $WarningMsg -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $ButtonType = "YesNo"
    $MessageboxTitle = "确定要继续吗？"
    $Messageboxbody = ("将卸载以下应用：`n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = "Information"

    $confirm = Show-WinUtilMessage -Message $Messageboxbody -Title $MessageboxTitle -Button $ButtonType -Icon $MessageIcon

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall requested for $(@($PackagesToUninstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToUninstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        Write-WinUtilLog -Component "Uninstall" -Message "Uninstall package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app uninstall (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if ($packagesWinget -contains "Microsoft.Edge") {
                New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force
            }

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在卸载 $program（$position/$totalPackages）" -Percent $startPercent
                    }

                    Install-WinUtilProgramWinget -Action Uninstall -Programs @($program)
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "已卸载 $program（$completedPackages/$totalPackages）" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "正在卸载 Chocolatey 软件包（$position/$totalPackages）" -Percent $startPercent
                }

                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "已卸载 Chocolatey 软件包（$completedPackages/$totalPackages）" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Uninstall" -Message "Uninstall workflow completed."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "应用卸载完成" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Uninstall" -Message "Uninstall workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "应用卸载失败" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }

    }
}

# [功能说明] Invoke-WPFUpdatesdefault：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    Write-WinUtilLog -Component "Updates" -Message "Resetting Windows Update settings to default."

    Write-Host "Removing Windows Update settings managed by WinUtil..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Removing Windows Update registry values managed by WinUtil."

    $registryValues = @(
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Names = @("NoAutoUpdate", "AUOptions", "NoAutoRebootWithLoggedOnUsers", "AUPowerManagement")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Names = @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
            Names = @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
            Names = @("PreventDeviceMetadataFromNetwork")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
            Names = @("DontPromptForWindowsUpdate", "DontSearchWindowsUpdate", "DriverUpdateWizardWuSearchEnabled")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
            Names = @("DODownloadMode")
        }
    )

    foreach ($registryEntry in $registryValues) {
        foreach ($valueName in $registryEntry.Names) {
            Remove-ItemProperty -Path $registryEntry.Path -Name $valueName -ErrorAction SilentlyContinue
        }
    }

    $explorerPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $settingsPageVisibility = (Get-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($settingsPageVisibility -eq "hide:windowsupdate") {
        Write-Host "Removing WinUtil's legacy Windows Update page restriction..."
        Write-WinUtilLog -Component "Updates" -Message "Removing the legacy Windows Update settings page restriction."
        Remove-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue
    }

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update service startup types."

    Write-Host "Restored BITS to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring BITS service to Manual."
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring wuauserv service to Manual."
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic."
    Write-WinUtilLog -Component "Updates" -Message "Starting UsoSvc service and restoring startup type to Automatic."
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Enabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update default workflow completed. Restart required."
}

# [功能说明] Invoke-WPFUpdatesdisable：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $confirmation = Show-WinUtilMessage `
        -Message "禁用 Windows 更新会停止更新服务、禁用计划任务并清理已下载的更新文件。恢复默认设置前不会安装安全更新。是否继续？" `
        -Title "禁用 Windows 更新？" `
        -Button "YesNo" `
        -Icon "Warning"

    if ($confirmation -ne "Yes") {
        Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow cancelled."
        return
    }

    Write-WinUtilLog -Component "Updates" -Message "Disabling Windows Update settings."

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Configuring Windows Update registry policy values for disable mode."
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    foreach ($serviceName in @("BITS", "wuauserv", "UsoSvc")) {
        Write-Host "Stopping and disabling $serviceName service."
        Write-WinUtilLog -Component "Updates" -Message "Stopping and disabling $serviceName service."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled
    }

    Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleared SoftwareDistribution folder."
    Write-WinUtilLog -Component "Updates" -Message "Cleared SoftwareDistribution folder."

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Disabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "--- Windows Update Is Disabled ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow completed. Restart required."
}

# [功能说明] Invoke-WPFUpdatessecurity：脚本内部函数（用于组织代码与复用逻辑）。

function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Defers feature updates for 365 days
        3. Defers quality updates for 4 days
        4. Prevents automatic restarts while a user is signed in

    #>

    Write-Host "Disabling driver offering through Windows Update..."
    Write-WinUtilLog -Component "Updates" -Message "Applying recommended Windows Update settings."
    Write-WinUtilLog -Component "Updates" -Message "Disabling driver offering through Windows Update."

    $windowsUpdatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $automaticUpdatePolicyPath = Join-Path $windowsUpdatePolicyPath "AU"

    Write-Host "Restoring Windows Update availability..."
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update services and scheduled tasks before applying recommended settings."

    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -ErrorAction SilentlyContinue

    Set-Service -Name BITS -StartupType Manual
    Set-Service -Name wuauserv -StartupType Manual
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path $windowsUpdatePolicyPath -Force
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Deferring feature updates by 365 days and quality updates by 4 days..."
    Write-WinUtilLog -Component "Updates" -Message "Deferring feature updates by 365 days and quality updates by 4 days."

    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    $legacySettingsPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    foreach ($legacyValue in @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")) {
        Remove-ItemProperty -Path $legacySettingsPath -Name $legacyValue -ErrorAction SilentlyContinue
    }

    Write-Host "Preventing automatic restarts while users are signed in..."
    Write-WinUtilLog -Component "Updates" -Message "Configuring scheduled automatic updates without restarting while users are signed in."

    New-Item -Path $automaticUpdatePolicyPath -Force
    # NoAutoRebootWithLoggedOnUsers only applies when automatic updates use option 4.
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUOptions" -Type DWord -Value 4
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Updates" -Message "Recommended Windows Update settings workflow completed."
}

$sync.configs.applications = @'
{
  "WPFInstall1password": {
    "category": "Utilities",
    "choco": "1password",
    "content": "1Password",
    "description": "1Password is a password manager that allows you to store and manage your passwords securely.",
    "link": "https://1password.com/",
    "winget": "AgileBits.1Password",
    "foss": false
  },
  "WPFInstall7zip": {
    "category": "Utilities",
    "choco": "7zip",
    "content": "7-Zip",
    "description": "7-Zip is a free and open-source file archiver utility. It supports several compression formats and provides a high compression ratio, making it a popular choice for file compression.",
    "link": "https://www.7-zip.org/",
    "winget": "7zip.7zip",
    "foss": true
  },
  "WPFInstalladobe": {
    "category": "Document",
    "choco": "adobereader",
    "content": "Adobe Acrobat Reader",
    "description": "Adobe Acrobat Reader is a free PDF viewer with essential features for viewing, printing, and annotating PDF documents.",
    "link": "https://www.adobe.com/acrobat/pdf-reader.html",
    "winget": "Adobe.Acrobat.Reader.64-bit",
    "foss": false
  },
  "WPFInstalladvancedip": {
    "category": "Pro Tools",
    "choco": "advanced-ip-scanner",
    "content": "Advanced IP Scanner",
    "description": "Advanced IP Scanner is a fast and easy-to-use network scanner. It is designed to analyze LAN networks and provides information about connected devices.",
    "link": "https://www.advanced-ip-scanner.com/",
    "winget": "Famatech.AdvancedIPScanner",
    "foss": false
  },
  "WPFInstallaimp": {
    "category": "Multimedia Tools",
    "choco": "aimp",
    "content": "AIMP (Music Player)",
    "description": "AIMP is a feature-rich music player with support for various audio formats, playlists, and customizable user interface.",
    "link": "https://www.aimp.ru/",
    "winget": "AIMP.AIMP",
    "foss": false
  },
  "WPFInstallangryipscanner": {
    "category": "Pro Tools",
    "choco": "angryip",
    "content": "Angry IP Scanner",
    "description": "Angry IP Scanner is an open-source and cross-platform network scanner. It is used to scan IP addresses and ports, providing information about network connectivity.",
    "link": "https://angryip.org/",
    "winget": "angryziber.AngryIPScanner",
    "foss": true
  },
  "WPFInstallanydesk": {
    "category": "Utilities",
    "choco": "anydesk",
    "content": "AnyDesk",
    "description": "AnyDesk is a remote desktop software that enables users to access and control computers remotely. It is known for its fast connection and low latency.",
    "link": "https://anydesk.com/",
    "winget": "AnyDesk.AnyDesk",
    "foss": false
  },
  "WPFInstallaudacity": {
    "category": "Multimedia Tools",
    "choco": "audacity",
    "content": "Audacity",
    "description": "Audacity is a free and open-source audio editing software known for its powerful recording and editing capabilities.",
    "link": "https://www.audacityteam.org/",
    "winget": "Audacity.Audacity",
    "foss": true
  },
  "WPFInstallautoruns": {
    "category": "Microsoft Tools",
    "choco": "autoruns",
    "content": "Autoruns",
    "description": "This utility shows you what programs are configured to run during system bootup or login.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
    "winget": "Microsoft.Sysinternals.Autoruns",
    "foss": false
  },
  "WPFInstallrdcman": {
    "category": "Microsoft Tools",
    "choco": "rdcman",
    "content": "RDCMan",
    "description": "RDCMan manages multiple remote desktop connections. It is useful for managing server labs where you need regular access to each machine such as automated checkin systems and data centers.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
    "winget": "Microsoft.Sysinternals.RDCMan",
    "foss": false
  },
  "WPFInstallautohotkey": {
    "category": "Utilities",
    "choco": "autohotkey",
    "content": "AutoHotkey",
    "description": "AutoHotkey is a scripting language for Windows that allows users to create custom automation scripts and macros. It is often used for automating repetitive tasks and customizing keyboard shortcuts.",
    "link": "https://www.autohotkey.com/",
    "winget": "AutoHotkey.AutoHotkey",
    "foss": true
  },
  "WPFInstallbitwarden": {
    "category": "Utilities",
    "choco": "bitwarden",
    "content": "Bitwarden",
    "description": "Bitwarden is an open-source password management solution. It allows users to store and manage their passwords in a secure and encrypted vault, accessible across multiple devices.",
    "link": "https://bitwarden.com/",
    "winget": "Bitwarden.Bitwarden",
    "foss": true
  },
  "WPFInstallblender": {
    "category": "Multimedia Tools",
    "choco": "blender",
    "content": "Blender (3D Graphics)",
    "description": "Blender is a powerful open-source 3D creation suite, offering modeling, sculpting, animation, and rendering tools.",
    "link": "https://www.blender.org/",
    "winget": "BlenderFoundation.Blender",
    "foss": true
  },
  "WPFInstallbrave": {
    "category": "Browsers",
    "choco": "brave",
    "content": "Brave",
    "description": "Brave is a privacy-focused web browser that blocks ads and trackers, offering a faster and safer browsing experience.",
    "link": "https://www.brave.com",
    "winget": "Brave.Brave",
    "foss": true
  },
  "WPFInstallbulkcrapuninstaller": {
    "category": "Utilities",
    "choco": "bulk-crap-uninstaller",
    "content": "Bulk Crap Uninstaller",
    "description": "Bulk Crap Uninstaller is a free and open-source uninstaller utility for Windows. It helps users remove unwanted programs and clean up their system by uninstalling multiple applications at once.",
    "link": "https://www.bcuninstaller.com/",
    "winget": "Klocman.BulkCrapUninstaller",
    "foss": true
  },
  "WPFInstallblurautoclicker": {
    "category": "Utilities",
    "choco": "na",
    "content": "BlurAutoClicker",
    "description": "An Auto-clicker with a few advanced features and generally better performance than popular alternatives.",
    "link": "https://blur009.vercel.app/projects/blur-autoclicker/",
    "winget": "Blur009.BlurAutoClicker",
    "foss": true
  },
  "WPFInstallcalibre": {
    "category": "Multimedia Tools",
    "choco": "calibre",
    "content": "Calibre",
    "description": "Calibre is a powerful and easy-to-use e-book manager, viewer, and converter.",
    "link": "https://calibre-ebook.com/",
    "winget": "calibre.calibre",
    "foss": true
  },
  "WPFInstallcemu": {
    "category": "Games",
    "choco": "cemu",
    "content": "Cemu",
    "description": "Cemu is a highly experimental software to emulate Wii U applications on PC.",
    "link": "https://cemu.info/",
    "winget": "Cemu.Cemu",
    "foss": true
  },
  "WPFInstallchatgpt": {
    "category": "Development",
    "choco": "na",
    "content": "ChatGPT Desktop",
    "description": "The official ChatGPT desktop app for Windows, distributed through the Microsoft Store.",
    "link": "https://apps.microsoft.com/detail/9nt1r1c2hh7j",
    "winget": "msstore:9NT1R1C2HH7J",
    "foss": false
  },
  "WPFInstallchatterino": {
    "category": "Communications",
    "choco": "chatterino",
    "content": "Chatterino",
    "description": "Chatterino is a chat client for Twitch chat that offers a clean and customizable interface for a better streaming experience.",
    "link": "https://www.chatterino.com/",
    "winget": "ChatterinoTeam.Chatterino",
    "foss": true
  },
  "WPFInstallchrome": {
    "category": "Browsers",
    "choco": "googlechrome",
    "content": "Chrome",
    "description": "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
    "link": "https://www.google.com/chrome/",
    "winget": "Google.Chrome",
    "foss": false
  },
  "WPFInstallchromium": {
    "category": "Browsers",
    "choco": "chromium",
    "content": "Chromium",
    "description": "Chromium is the open-source project that serves as the foundation for various web browsers, including Chrome.",
    "link": "https://github.com/Hibbiki/chromium-win64",
    "winget": "Hibbiki.Chromium",
    "foss": true
  },
  "WPFInstallcinebenchr23": {
    "category": "Pro Tools",
    "choco": "na",
    "content": "Cinebench R23",
    "description": "Cinebench R23 is a benchmark tool for comparing CPU rendering performance across systems.",
    "link": "https://www.maxon.net/en/cinebench",
    "winget": "Maxon.CinebenchR23",
    "foss": false
  },
  "WPFInstallclaude": {
    "category": "Development",
    "choco": "claude",
    "content": "Claude Desktop",
    "description": "Anthropic's Claude desktop application for focused AI-assisted work and chat.",
    "link": "https://claude.ai/download",
    "winget": "Anthropic.Claude",
    "foss": false
  },
  "WPFInstallclaude-code": {
    "category": "Development",
    "choco": "claude-code",
    "content": "Claude Code",
    "description": "Anthropic's agentic coding tool for terminal and IDE development workflows.",
    "link": "https://code.claude.com/",
    "winget": "Anthropic.ClaudeCode",
    "foss": false
  },
  "WPFInstallcmake": {
    "category": "Development",
    "choco": "cmake",
    "content": "CMake",
    "description": "CMake is an open-source, cross-platform family of tools designed to build, test and package software.",
    "link": "https://cmake.org/",
    "winget": "Kitware.CMake",
    "foss": true
  },
  "WPFInstallcodex": {
    "category": "Development",
    "choco": "codex",
    "content": "Codex",
    "description": "Codex CLI is an OpenAI coding agent that runs locally in your terminal.",
    "link": "https://developers.openai.com/codex/cli",
    "winget": "OpenAI.Codex",
    "foss": true
  },
  "WPFInstallcpuz": {
    "category": "Pro Tools",
    "choco": "cpu-z",
    "content": "CPU-Z",
    "description": "CPU-Z is a system monitoring and diagnostic tool for Windows. It provides detailed information about the computer's hardware components, including the CPU, memory, and motherboard.",
    "link": "https://www.cpuid.com/softwares/cpu-z.html",
    "winget": "CPUID.CPU-Z",
    "foss": false
  },
  "WPFInstallcrystaldiskinfo": {
    "category": "Utilities",
    "choco": "crystaldiskinfo",
    "content": "Crystal Disk Info",
    "description": "Crystal Disk Info is a disk health monitoring tool that provides information about the status and performance of hard drives. It helps users anticipate potential issues and monitor drive health.",
    "link": "https://crystalmark.info/en/software/crystaldiskinfo/",
    "winget": "CrystalDewWorld.CrystalDiskInfo",
    "foss": true
  },
  "WPFInstallcrystaldiskmark": {
    "category": "Utilities",
    "choco": "crystaldiskmark",
    "content": "Crystal Disk Mark",
    "description": "Crystal Disk Mark is a disk benchmarking tool that measures the read and write speeds of storage devices. It helps users assess the performance of their hard drives and SSDs.",
    "link": "https://crystalmark.info/en/software/crystaldiskmark/",
    "winget": "CrystalDewWorld.CrystalDiskMark",
    "foss": true
  },
  "WPFInstallcursor": {
    "category": "Development",
    "choco": "cursoride",
    "content": "Cursor",
    "description": "AI-powered code editor (VS Code-based) with agentic coding features and integrated AI assistance for development workflows.",
    "link": "https://cursor.com/",
    "winget": "Anysphere.Cursor",
    "foss": false
  },
  "WPFInstallddu": {
    "category": "Pro Tools",
    "choco": "ddu",
    "content": "Display Driver Uninstaller",
    "description": "Display Driver Uninstaller (DDU) is a tool for completely uninstalling graphics drivers from NVIDIA, AMD, and Intel. It is useful for troubleshooting graphics driver-related issues.",
    "link": "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
    "winget": "Wagnardsoft.DisplayDriverUninstaller",
    "foss": true
  },
  "WPFInstalldiscord": {
    "category": "Communications",
    "choco": "discord",
    "content": "Discord",
    "description": "Discord is a popular communication platform with voice, video, and text chat, designed for gamers but used by a wide range of communities.",
    "link": "https://discord.com/",
    "winget": "Discord.Discord",
    "foss": false
  },
  "WPFInstalldismtools": {
    "category": "Microsoft Tools",
    "choco": "dismtools",
    "content": "DISMTools",
    "description": "DISMTools is a fast, customizable GUI for the DISM utility, supporting Windows images from Windows 7 onward. It handles installations on any drive, offers project support, and lets users tweak settings like color modes, language, and DISM versions; powered by both native DISM and a managed DISM API.",
    "link": "https://github.com/CodingWonders/DISMTools",
    "winget": "CodingWondersSoftware.DISMTools.Stable",
    "foss": true
  },
  "WPFInstallntlite": {
    "category": "Microsoft Tools",
    "choco": "ntlite-free",
    "content": "NTLite",
    "description": "Integrate updates, drivers, automate Windows and application setup, speedup Windows deployment process and have it all set for the next time.",
    "link": "https://ntlite.com",
    "winget": "Nlitesoft.NTLite",
    "foss": false
  },
  "WPFInstalldorion": {
    "category": "Communications",
    "choco": "dorion",
    "content": "Dorion",
    "description": "Tiny alternative Discord client with a smaller footprint, snappier startup, themes, plugins and more!",
    "link": "https://github.com/SpikeHD/Dorion",
    "winget": "SpikeHD.Dorion",
    "foss": true
  },
  "WPFInstalldotnet6": {
    "category": "Microsoft Tools",
    "choco": "dotnet-6.0-runtime",
    "content": ".NET Desktop Runtime 6",
    "description": ".NET Desktop Runtime 6 is a runtime environment required for running applications developed with .NET 6.",
    "link": "https://dotnet.microsoft.com/download/dotnet/6.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.6",
    "foss": true
  },
  "WPFInstalldotnet8": {
    "category": "Microsoft Tools",
    "choco": "dotnet-8.0-runtime",
    "content": ".NET Desktop Runtime 8",
    "description": ".NET Desktop Runtime 8 is a runtime environment required for running applications developed with .NET 8.",
    "link": "https://dotnet.microsoft.com/download/dotnet/8.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.8",
    "foss": true
  },
  "WPFInstalldotnet9": {
    "category": "Microsoft Tools",
    "choco": "dotnet-9.0-runtime",
    "content": ".NET Desktop Runtime 9",
    "description": ".NET Desktop Runtime 9 is a runtime environment required for running applications developed with .NET 9.",
    "link": "https://dotnet.microsoft.com/download/dotnet/9.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.9",
    "foss": true
  },
  "WPFInstalldotnet10": {
    "category": "Microsoft Tools",
    "choco": "dotnet-10.0-runtime",
    "content": ".NET Desktop Runtime 10",
    "description": ".NET Desktop Runtime 10 is a runtime environment required for running applications developed with .NET 10.",
    "link": "https://dotnet.microsoft.com/download/dotnet/10.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.10",
    "foss": true
  },
  "WPFInstalldropbox": {
    "category": "Utilities",
    "choco": "dropbox",
    "content": "Dropbox",
    "description": "Dropbox is a cloud storage client for syncing files, sharing content, and keeping documents available across devices.",
    "link": "https://www.dropbox.com/desktop",
    "winget": "Dropbox.Dropbox",
    "foss": false
  },
  "WPFInstalleaapp": {
    "category": "Games",
    "choco": "ea-app",
    "content": "EA App",
    "description": "EA App is a platform for accessing and playing Electronic Arts games.",
    "link": "https://www.ea.com/ea-app",
    "winget": "ElectronicArts.EADesktop",
    "foss": false
  },
  "WPFInstalleartrumpet": {
    "category": "Multimedia Tools",
    "choco": "eartrumpet",
    "content": "EarTrumpet (Audio)",
    "description": "EarTrumpet is an audio control app for Windows, providing a simple and intuitive interface for managing sound settings.",
    "link": "https://eartrumpet.app/",
    "winget": "File-New-Project.EarTrumpet",
    "foss": true
  },
  "WPFInstalledge": {
    "category": "Browsers",
    "choco": "microsoft-edge",
    "content": "Edge",
    "description": "Microsoft Edge is a modern web browser built on Chromium, offering performance, security, and integration with Microsoft services.",
    "link": "https://www.microsoft.com/edge",
    "winget": "Microsoft.Edge",
    "foss": false
  },
  "WPFInstallenteauth": {
    "category": "Utilities",
    "choco": "ente-auth",
    "content": "Ente Auth",
    "description": "Ente Auth is a free, cross-platform, end-to-end encrypted authenticator app.",
    "link": "https://ente.io/auth/",
    "winget": "ente-io.auth-desktop",
    "foss": true
  },
  "WPFInstallepicgames": {
    "category": "Games",
    "choco": "epicgameslauncher",
    "content": "Epic Games Launcher",
    "description": "Epic Games Launcher is the client for accessing and playing games from the Epic Games Store.",
    "link": "https://www.epicgames.com/store/en-US/",
    "winget": "EpicGames.EpicGamesLauncher",
    "foss": false
  },
  "WPFInstallfiles": {
    "category": "Utilities",
    "choco": "files",
    "content": "Files",
    "description": "Alternative file explorer.",
    "link": "https://github.com/files-community/Files",
    "winget": "FilesCommunity.Files",
    "foss": true
  },
  "WPFInstallfirefox": {
    "category": "Browsers",
    "choco": "firefox",
    "content": "Firefox",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "winget": "Mozilla.Firefox",
    "foss": true
  },
  "WPFInstallfirefoxesr": {
    "category": "Browsers",
    "choco": "FirefoxESR",
    "content": "Firefox ESR",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions. Firefox ESR (Extended Support Release) receives major updates every 42 weeks with minor updates such as crash fixes, security fixes and policy updates as needed, but at least every four weeks.",
    "link": "https://www.mozilla.org/en-US/firefox/enterprise/",
    "winget": "Mozilla.Firefox.ESR",
    "foss": true
  },
  "WPFInstallfloorp": {
    "category": "Browsers",
    "choco": "floorp",
    "content": "Floorp",
    "description": "Floorp is an open-source web browser project that aims to provide a simple and fast browsing experience.",
    "link": "https://floorp.app/",
    "winget": "Ablaze.Floorp",
    "foss": true
  },
  "WPFInstallflux": {
    "category": "Utilities",
    "choco": "flux",
    "content": "F.lux",
    "description": "f.lux adjusts the color temperature of your screen to reduce eye strain during nighttime use.",
    "link": "https://justgetflux.com/",
    "winget": "flux.flux",
    "foss": false
  },
  "WPFInstallfoxpdfreader": {
    "category": "Document",
    "choco": "foxitreader",
    "content": "Foxit PDF Reader",
    "description": "Foxit PDF Reader is a free PDF viewer with a familiar ribbon-style interface.",
    "link": "https://www.foxit.com/pdf-reader/",
    "winget": "Foxit.FoxitReader",
    "foss": false
  },
  "WPFInstallgeforcenow": {
    "category": "Games",
    "choco": "nvidia-geforce-now",
    "content": "GeForce NOW",
    "description": "GeForce NOW is a cloud gaming service that allows you to play high-quality PC games on your device.",
    "link": "https://www.nvidia.com/en-us/geforce-now/",
    "winget": "Nvidia.GeForceNow",
    "foss": false
  },
  "WPFInstallgimp": {
    "category": "Multimedia Tools",
    "choco": "gimp",
    "content": "GIMP (Image Editor)",
    "description": "GIMP is a versatile open-source raster graphics editor used for tasks such as photo retouching, image editing, and image composition.",
    "link": "https://www.gimp.org/",
    "winget": "GIMP.GIMP.3",
    "foss": true
  },
  "WPFInstallgit": {
    "category": "Development",
    "choco": "git",
    "content": "Git",
    "description": "Git is a distributed version control system widely used for tracking changes in source code during software development.",
    "link": "https://git-scm.com/",
    "winget": "Git.Git",
    "foss": true
  },
  "WPFInstallgithubdesktop": {
    "category": "Development",
    "choco": "git;github-desktop",
    "content": "GitHub Desktop",
    "description": "GitHub Desktop is a visual Git client that simplifies collaboration on GitHub repositories with an easy-to-use interface.",
    "link": "https://desktop.github.com/",
    "winget": "GitHub.GitHubDesktop",
    "foss": true
  },
  "WPFInstallgog": {
    "category": "Games",
    "choco": "goggalaxy",
    "content": "GOG Galaxy",
    "description": "GOG Galaxy is a gaming client that offers DRM-free games, additional content, and more.",
    "link": "https://www.gog.com/galaxy",
    "winget": "GOG.Galaxy",
    "foss": false
  },
  "WPFInstallgolang": {
    "category": "Development",
    "choco": "golang",
    "content": "Go",
    "description": "Go (or Golang) is a statically typed, compiled programming language designed for simplicity, reliability, and efficiency.",
    "link": "https://go.dev/",
    "winget": "GoLang.Go",
    "foss": true
  },
  "WPFInstallgoogledrive": {
    "category": "Utilities",
    "choco": "googledrive",
    "content": "Google Drive",
    "description": "File syncing across devices all tied to your Google account.",
    "link": "https://www.google.com/drive/",
    "winget": "Google.GoogleDrive",
    "foss": false
  },
  "WPFInstallgpuz": {
    "category": "Pro Tools",
    "choco": "gpu-z",
    "content": "GPU-Z",
    "description": "GPU-Z provides detailed information about your graphics card and GPU.",
    "link": "https://www.techpowerup.com/gpuz/",
    "winget": "TechPowerUp.GPU-Z",
    "foss": false
  },
  "WPFInstallgsudo": {
    "category": "Pro Tools",
    "choco": "gsudo",
    "content": "gsudo",
    "description": "gsudo is a sudo equivalent for Windows. It allows you to run commands with elevated administrative privileges directly within the current console window.",
    "link": "https://github.com/gerardog/gsudo",
    "winget": "gerardog.gsudo",
    "foss": true
  },
  "WPFInstallhelium": {
    "category": "Browsers",
    "choco": "helium",
    "content": "Helium",
    "description": "Private, fast, and honest web browser.",
    "link": "https://github.com/imputnet/helium/",
    "winget": "ImputNet.Helium",
    "foss": true
  },
  "WPFInstallhugo": {
    "category": "Utilities",
    "choco": "hugo-extended",
    "content": "Hugo",
    "description": "The world's fastest framework for building websites.",
    "link": "https://github.com/gohugoio/hugo/",
    "winget": "Hugo.Hugo.Extended",
    "foss": true
  },
  "WPFInstallhandbrake": {
    "category": "Multimedia Tools",
    "choco": "handbrake",
    "content": "HandBrake",
    "description": "HandBrake is an open-source video transcoder, allowing you to convert video from nearly any format to a selection of widely supported codecs.",
    "link": "https://handbrake.fr/",
    "winget": "HandBrake.HandBrake",
    "foss": true
  },
  "WPFInstallheroiclauncher": {
    "category": "Games",
    "choco": "heroic-games-launcher",
    "content": "Heroic Games Launcher",
    "description": "Heroic Games Launcher is an open-source alternative game launcher for Epic Games Store.",
    "link": "https://heroicgameslauncher.com/",
    "winget": "HeroicGamesLauncher.HeroicGamesLauncher",
    "foss": true
  },
  "WPFInstallhwinfo": {
    "category": "Pro Tools",
    "choco": "hwinfo",
    "content": "HWiNFO",
    "description": "HWiNFO provides comprehensive hardware information and diagnostics for Windows.",
    "link": "https://www.hwinfo.com/",
    "winget": "REALiX.HWiNFO",
    "foss": false
  },
  "WPFInstallhwmonitor": {
    "category": "Pro Tools",
    "choco": "hwmonitor",
    "content": "HWMonitor",
    "description": "HWMonitor is a hardware monitoring program that reads PC systems main health sensors.",
    "link": "https://www.cpuid.com/softwares/hwmonitor.html",
    "winget": "CPUID.HWMonitor",
    "foss": false
  },
  "WPFInstallimageglass": {
    "category": "Multimedia Tools",
    "choco": "imageglass",
    "content": "ImageGlass (Image Viewer)",
    "description": "ImageGlass is a versatile image viewer with support for various image formats and a focus on simplicity and speed.",
    "link": "https://imageglass.org/",
    "winget": "DuongDieuPhap.ImageGlass",
    "foss": true
  },
  "WPFInstallinternetdownloadmanager": {
    "category": "Utilities",
    "choco": "internet-download-manager",
    "content": "Internet Download Manager",
    "description": "Internet Download Manager is a download manager for accelerating, resuming, and scheduling file downloads.",
    "link": "https://www.internetdownloadmanager.com/",
    "winget": "Tonec.InternetDownloadManager",
    "foss": false
  },
  "WPFInstallirfanview": {
    "category": "Multimedia Tools",
    "choco": "irfanview",
    "content": "IrfanView",
    "description": "IrfanView is a lightweight, fast, and free image viewer and editor. Supports multiple formats, batch processing, and powerful plugins.",
    "link": "https://irfanview.com/",
    "winget": "IrfanSkiljan.IrfanView",
    "foss": false
  },
  "WPFInstallitch": {
    "category": "Games",
    "choco": "itch",
    "content": "Itch.io",
    "description": "Itch.io is a digital distribution platform for indie games and creative projects.",
    "link": "https://itch.io/",
    "winget": "ItchIo.Itch",
    "foss": true
  },
  "WPFInstallitunes": {
    "category": "Multimedia Tools",
    "choco": "itunes",
    "content": "iTunes",
    "description": "iTunes is a media player, media library, and online radio broadcaster application developed by Apple Inc.",
    "link": "https://www.apple.com/itunes/",
    "winget": "Apple.iTunes",
    "foss": false
  },
  "WPFInstalljava8": {
    "category": "Development",
    "choco": "corretto8jdk",
    "content": "Amazon Corretto 8 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.8.JDK",
    "foss": true
  },
  "WPFInstalljava21": {
    "category": "Development",
    "choco": "corretto21jdk",
    "content": "Amazon Corretto 21 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.21.JDK",
    "foss": true
  },
  "WPFInstalljava25": {
    "category": "Development",
    "choco": "corretto25jdk",
    "content": "Amazon Corretto 25 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.25.JDK",
    "foss": true
  },
  "WPFInstalljellyfinmediaplayer": {
    "category": "Selfhosted Tools",
    "choco": "jellyfin-media-player",
    "content": "Jellyfin Media Player",
    "description": "Jellyfin Media Player is a client application for the Jellyfin media server, providing access to your media library.",
    "link": "https://github.com/jellyfin/jellyfin-media-player",
    "winget": "Jellyfin.JellyfinMediaPlayer",
    "foss": true
  },
  "WPFInstalljellyfinserver": {
    "category": "Selfhosted Tools",
    "choco": "jellyfin",
    "content": "Jellyfin Server",
    "description": "Jellyfin Server is an open-source media server software, allowing you to organize and stream your media library.",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.Server",
    "foss": true
  },
  "WPFInstalljetbrains": {
    "category": "Development",
    "choco": "jetbrainstoolbox",
    "content": "Jetbrains Toolbox",
    "description": "Jetbrains Toolbox is a platform for easy installation and management of JetBrains developer tools.",
    "link": "https://www.jetbrains.com/toolbox/",
    "winget": "JetBrains.Toolbox",
    "foss": false
  },
  "WPFInstalljpegview": {
    "category": "Utilities",
    "choco": "jpegview",
    "content": "JPEG View",
    "description": "JPEGView is a lean, fast and highly configurable viewer/editor for JPEG, BMP, PNG, WEBP, TGA, GIF, JXL, HEIC, HEIF, AVIF, and TIFF images with a minimal GUI.",
    "link": "https://github.com/sylikc/jpegview",
    "winget": "sylikc.JPEGView",
    "foss": true
  },
  "WPFInstalljoplin": {
    "category": "Document",
    "choco": "joplin",
    "content": "Joplin",
    "description": "Joplin is an open-source note-taking and to-do application with synchronization capabilities.",
    "link": "https://joplinapp.org/",
    "winget": "Joplin.Joplin",
    "foss": true
  },
  "WPFInstallkeepassxc": {
    "category": "Utilities",
    "choco": "keepassxc",
    "content": "KeePassXC",
    "description": "KeePassXC is a modern, secure, and open-source password manager that stores and manages your most sensitive information. You can run KeePassXC on Windows, macOS, and Linux systems. KeePassXC is for people with extremely high demands of secure personal data management. It saves many different types of information, such as usernames, passwords, URLs, attachments, and notes in an offline, encrypted file that can be stored in any location, including private and public cloud solutions. For easy identification and management, user-defined titles and icons can be specified for entries. In addition, entries are sorted into customizable groups. An integrated search function allows you to use advanced patterns to easily find any entry in your database. A customizable, fast, and easy-to-use password generator utility allows you to create passwords with any combination of characters or easy to remember passphrases.",
    "link": "https://keepassxc.org/",
    "winget": "KeePassXCTeam.KeePassXC",
    "foss": true
  },
  "WPFInstallklite": {
    "category": "Multimedia Tools",
    "choco": "k-litecodecpack-standard",
    "content": "K-Lite Codec Standard",
    "description": "K-Lite Codec Pack Standard is a collection of audio and video codecs and related tools, providing essential components for media playback.",
    "link": "https://www.codecguide.com/",
    "winget": "CodecGuide.K-LiteCodecPack.Standard",
    "foss": false
  },
  "WPFInstallkodi": {
    "category": "Selfhosted Tools",
    "choco": "kodi",
    "content": "Kodi Media Center",
    "description": "Kodi is an open-source media center application that allows you to play and view most videos, music, podcasts, and other digital media files.",
    "link": "https://kodi.tv/",
    "winget": "XBMCFoundation.Kodi",
    "foss": true
  },
  "WPFInstalllazygit": {
    "category": "Development",
    "choco": "lazygit",
    "content": "Lazygit",
    "description": "Simple terminal UI for git commands.",
    "link": "https://github.com/jesseduffield/lazygit/",
    "winget": "JesseDuffield.lazygit",
    "foss": true
  },
  "WPFInstalllibreoffice": {
    "category": "Document",
    "choco": "libreoffice-fresh",
    "content": "LibreOffice",
    "description": "LibreOffice is a powerful and free office suite, compatible with other major office suites.",
    "link": "https://www.libreoffice.org/",
    "winget": "TheDocumentFoundation.LibreOffice",
    "foss": true
  },
  "WPFInstalllibrewolf": {
    "category": "Browsers",
    "choco": "librewolf",
    "content": "LibreWolf",
    "description": "LibreWolf is a privacy-focused web browser based on Firefox, with additional privacy and security enhancements.",
    "link": "https://librewolf-community.gitlab.io/",
    "winget": "LibreWolf.LibreWolf",
    "foss": true
  },
  "WPFInstalllocalsend": {
    "category": "Selfhosted Tools",
    "choco": "localsend.install",
    "content": "LocalSend",
    "description": "An open-source cross-platform alternative to AirDrop.",
    "link": "https://localsend.org/",
    "winget": "LocalSend.LocalSend",
    "foss": true
  },
  "WPFInstallmpc-qt": {
    "category": "Multimedia Tools",
    "choco": "mediainfo",
    "content": "mpc-qt",
    "description": "Media Player Classic Qute Theater",
    "link": "https://github.com/mpc-qt/mpc-qt",
    "winget": "mpc-qt.mpc-qt",
    "foss": true
  },
  "WPFInstallmatrix": {
    "category": "Communications",
    "choco": "element-desktop",
    "content": "Element",
    "description": "Element is a client for Matrix; an open network for secure, decentralized communication.",
    "link": "https://element.io/",
    "winget": "Element.Element",
    "foss": true
  },
  "WPFInstallminitoolpartitionwizard": {
    "category": "Utilities",
    "choco": "minitoolpartitionwizard",
    "content": "MiniTool Partition Wizard",
    "description": "Comprehensive free partition manager that performs advanced operations Windows natively cannot, such as merging partitions, converting file systems, and organizing disk capacity.",
    "link": "https://www.partitionwizard.com/",
    "winget": "MiniTool.PartitionWizard.Free",
    "foss": false
  },
  "WPFInstallmodrinth": {
    "category": "Games",
    "choco": "modrinth-app",
    "content": "Modrinth App",
    "description": "Modrinth App is a desktop application for managing Minecraft mods and modpacks.",
    "link": "https://modrinth.com/app",
    "winget": "Modrinth.ModrinthApp",
    "foss": true
  },
  "WPFInstallmoonlight": {
    "category": "Selfhosted Tools",
    "choco": "moonlight-qt",
    "content": "Moonlight/GameStream Client",
    "description": "Moonlight/GameStream Client allows you to stream PC games to other devices over your local network.",
    "link": "https://moonlight-stream.org/",
    "winget": "MoonlightGameStreamingProject.Moonlight",
    "foss": true
  },
  "WPFInstallmpchc": {
    "category": "Multimedia Tools",
    "choco": "mpc-hc-clsid2",
    "content": "Media Player Classic - Home Cinema",
    "description": "Media Player Classic - Home Cinema (MPC-HC) is a free and open-source video and audio player for Windows. MPC-HC is based on the original Guliverkli project and contains many additional features and bug fixes.",
    "link": "https://github.com/clsid2/mpc-hc/",
    "winget": "clsid2.mpc-hc",
    "foss": true
  },
  "WPFInstallmsedgeredirect": {
    "category": "Utilities",
    "choco": "msedgeredirect",
    "content": "MSEdgeRedirect",
    "description": "A Tool to Redirect News, Search, Widgets, Weather, and More to your default browser.",
    "link": "https://github.com/rcmaehl/MSEdgeRedirect",
    "winget": "rcmaehl.MSEdgeRedirect",
    "foss": true
  },
  "WPFInstallmsiafterburner": {
    "category": "Utilities",
    "choco": "msiafterburner",
    "content": "MSI Afterburner",
    "description": "MSI Afterburner is a graphics card overclocking utility with advanced features.",
    "link": "https://www.msi.com/Landing/afterburner",
    "winget": "Guru3D.Afterburner",
    "foss": false
  },
  "WPFInstallmullvadvpn": {
    "category": "Pro Tools",
    "choco": "mullvad-app",
    "content": "Mullvad VPN",
    "description": "This is the VPN client software for the Mullvad VPN service.",
    "link": "https://github.com/mullvad/mullvadvpn-app",
    "winget": "MullvadVPN.MullvadVPN",
    "foss": true
  },
  "WPFInstallmullvadbrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Mullvad Browser",
    "description": "Mullvad Browser is a privacy-focused web browser, developed in partnership with the Tor Project.",
    "link": "https://mullvad.net/browser",
    "winget": "MullvadVPN.MullvadBrowser",
    "foss": true
  },
  "WPFInstallnomacs": {
    "category": "Multimedia Tools",
    "choco": "nomacs",
    "content": "nomacs",
    "description": "nomacs is a free, open-source image viewer, which supports multiple platforms. You can use it for viewing all common image formats, including RAW and .psd images.",
    "link": "https://nomacs.org/",
    "winget": "nomacs.nomacs",
    "foss": true
  },
  "WPFInstallnanazip": {
    "category": "Utilities",
    "choco": "nanazip",
    "content": "NanaZip",
    "description": "NanaZip is a fast and efficient file compression and decompression tool.",
    "link": "https://github.com/M2Team/NanaZip",
    "winget": "M2Team.NanaZip",
    "foss": true
  },
  "WPFInstallnetbird": {
    "category": "Selfhosted Tools",
    "choco": "netbird",
    "content": "NetBird",
    "description": "NetBird is an open-source alternative comparable to TailScale that can be connected to a self-hosted server.",
    "link": "https://netbird.io/",
    "winget": "Netbird.Netbird",
    "foss": true
  },
  "WPFInstallnaps2": {
    "category": "Document",
    "choco": "naps2",
    "content": "NAPS2 (Scanner)",
    "description": "NAPS2 is a document scanning application that simplifies the process of creating electronic documents.",
    "link": "https://www.naps2.com/",
    "winget": "Cyanfish.NAPS2",
    "foss": true
  },
  "WPFInstallneovim": {
    "category": "Development",
    "choco": "neovim",
    "content": "Neovim",
    "description": "Neovim is a highly extensible text editor and an improvement over the original Vim editor.",
    "link": "https://neovim.io/",
    "winget": "Neovim.Neovim",
    "foss": true
  },
  "WPFInstallnextclouddesktop": {
    "category": "Selfhosted Tools",
    "choco": "nextcloud-client",
    "content": "Nextcloud Desktop",
    "description": "Nextcloud Desktop is the official desktop client for the Nextcloud file synchronization and sharing platform.",
    "link": "https://nextcloud.com/install/#install-clients",
    "winget": "Nextcloud.NextcloudDesktop",
    "foss": true
  },
  "WPFInstallnmap": {
    "category": "Pro Tools",
    "choco": "nmap",
    "content": "Nmap",
    "description": "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
    "link": "https://nmap.org/",
    "winget": "Insecure.Nmap",
    "foss": true
  },
  "WPFInstallnodejs": {
    "category": "Development",
    "choco": "nodejs",
    "content": "NodeJS",
    "description": "NodeJS is a JavaScript runtime built on Chrome's V8 JavaScript engine for building server-side and networking applications.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS",
    "foss": true
  },
  "WPFInstallnodejslts": {
    "category": "Development",
    "choco": "nodejs-lts",
    "content": "NodeJS LTS",
    "description": "NodeJS LTS provides Long-Term Support releases for stable and reliable server-side JavaScript development.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS.LTS",
    "foss": true
  },
  "WPFInstallpnpm": {
    "category": "Development",
    "content": "pnpm",
    "description": "pnpm is a fast and disk space efficient package manager for JavaScript and Node.js applications.",
    "link": "https://pnpm.io/",
    "winget": "pnpm.pnpm",
    "foss": true
  },
  "WPFInstallnotepadplus": {
    "category": "Multimedia Tools",
    "choco": "notepadplusplus",
    "content": "Notepad++",
    "description": "Notepad++ is a free, open-source code editor and Notepad replacement with support for multiple languages.",
    "link": "https://notepad-plus-plus.org/",
    "winget": "Notepad++.Notepad++",
    "foss": true
  },
  "WPFInstallnuget": {
    "category": "Microsoft Tools",
    "choco": "nuget.commandline",
    "content": "NuGet",
    "description": "NuGet is a package manager for the .NET framework, enabling developers to manage and share libraries in their .NET applications.",
    "link": "https://www.nuget.org/",
    "winget": "Microsoft.NuGet",
    "foss": true
  },
  "WPFInstallnvclean": {
    "category": "Utilities",
    "choco": "na",
    "content": "NVCleanstall",
    "description": "NVCleanstall is a tool designed to customize NVIDIA driver installations, allowing advanced users to control more aspects of the installation process.",
    "link": "https://www.techpowerup.com/nvcleanstall/",
    "winget": "TechPowerUp.NVCleanstall",
    "foss": false
  },
  "WPFInstallobs": {
    "category": "Multimedia Tools",
    "choco": "obs-studio",
    "content": "OBS Studio",
    "description": "OBS Studio is a free and open-source software for video recording and live streaming. It supports real-time video/audio capturing and mixing, making it popular among content creators.",
    "link": "https://obsproject.com/",
    "winget": "OBSProject.OBSStudio",
    "foss": true
  },
  "WPFInstallobsidian": {
    "category": "Document",
    "choco": "obsidian",
    "content": "Obsidian",
    "description": "Obsidian is a powerful note-taking and knowledge management application.",
    "link": "https://obsidian.md/",
    "winget": "Obsidian.Obsidian",
    "foss": false
  },
  "WPFInstallokular": {
    "category": "Document",
    "choco": "okular",
    "content": "Okular",
    "description": "Okular is a versatile document viewer with advanced features.",
    "link": "https://okular.kde.org/",
    "winget": "KDE.Okular",
    "foss": true
  },
  "WPFInstallonedrive": {
    "category": "Microsoft Tools",
    "choco": "onedrive",
    "content": "OneDrive",
    "description": "OneDrive is a cloud storage service provided by Microsoft, allowing users to store and share files securely across devices.",
    "link": "https://onedrive.live.com/",
    "winget": "Microsoft.OneDrive",
    "foss": false
  },
  "WPFInstallonlyoffice": {
    "category": "Document",
    "choco": "onlyoffice",
    "content": "ONLYOFFICE Desktop",
    "description": "ONLYOFFICE Desktop is a comprehensive office suite for document editing and collaboration.",
    "link": "https://www.onlyoffice.com/desktop.aspx",
    "winget": "ONLYOFFICE.DesktopEditors",
    "foss": true
  },
  "WPFInstallOPAutoClicker": {
    "category": "Utilities",
    "choco": "autoclicker",
    "content": "OPAutoClicker",
    "description": "A full-fledged autoclicker with two modes of autoclicking, at your dynamic cursor location or at a prespecified location.",
    "link": "https://www.opautoclicker.com",
    "winget": "OPAutoClicker.OPAutoClicker",
    "foss": false
  },
  "WPFInstallopenrgb": {
    "category": "Utilities",
    "choco": "openrgb",
    "content": "OpenRGB",
    "description": "OpenRGB is an open-source RGB lighting control software designed to manage and control RGB lighting for various components and peripherals.",
    "link": "https://openrgb.org/",
    "winget": "OpenRGB.OpenRGB",
    "foss": true
  },
  "WPFInstallOpenVPN": {
    "category": "Pro Tools",
    "choco": "openvpn-connect",
    "content": "OpenVPN Connect",
    "description": "OpenVPN Connect is a VPN client that allows you to connect securely to a VPN server. It provides a secure and encrypted connection for protecting your online privacy.",
    "link": "https://openvpn.net/",
    "winget": "OpenVPNTechnologies.OpenVPNConnect",
    "foss": false
  },
  "WPFInstallOVirtualBox": {
    "category": "Utilities",
    "choco": "virtualbox",
    "content": "Oracle VirtualBox",
    "description": "Oracle VirtualBox is a powerful and free open-source virtualization tool for x86 and AMD64/Intel64 architectures.",
    "link": "https://www.virtualbox.org/",
    "winget": "Oracle.VirtualBox",
    "foss": true
  },
  "WPFInstallpolicyplus": {
    "category": "Utilities",
    "choco": "na",
    "content": "Policy Plus",
    "description": "Local Group Policy Editor plus more, for all Windows editions.",
    "link": "https://github.com/Fleex255/PolicyPlus",
    "winget": "Fleex255.PolicyPlus",
    "foss": true
  },
  "WPFInstallprocessexplorer": {
    "category": "Microsoft Tools",
    "choco": "procexp",
    "content": "Process Explorer",
    "description": "Process Explorer is a task manager and system monitor.",
    "link": "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
    "winget": "Microsoft.Sysinternals.ProcessExplorer",
    "foss": false
  },
  "WPFInstallPaintdotnet": {
    "category": "Multimedia Tools",
    "choco": "paint.net",
    "content": "Paint.NET",
    "description": "Paint.NET is a free image and photo editing software for Windows. It features an intuitive user interface and supports a wide range of powerful editing tools.",
    "link": "https://www.getpaint.net/",
    "winget": "dotPDN.PaintDotNet",
    "foss": false
  },
  "WPFInstallparsec": {
    "category": "Utilities",
    "choco": "parsec",
    "content": "Parsec",
    "description": "Parsec is a low-latency, high-quality remote desktop sharing application for collaborating and gaming across devices.",
    "link": "https://parsec.app/",
    "winget": "Parsec.Parsec",
    "foss": false
  },
  "WPFInstallpeazip": {
    "category": "Utilities",
    "choco": "peazip",
    "content": "PeaZip",
    "description": "PeaZip is a free, open-source file archiver utility that supports multiple archive formats and provides encryption features.",
    "link": "https://peazip.github.io/",
    "winget": "Giorgiotani.Peazip",
    "foss": true
  },
  "WPFInstallpdf-xchange": {
    "category": "Document",
    "choco": "pdfxchangeeditor",
    "content": "PDF-XChange Editor",
    "description": "A comprehensive Windows-based software suite and editor for creating, viewing, editing, annotating, and signing PDF files.",
    "link": "https://www.pdf-xchange.com/",
    "winget": "TrackerSoftware.PDF-XChangeEditor",
    "foss": false
  },
  "WPFInstallpdf24creator": {
    "category": "Document",
    "choco": "pdf24",
    "content": "PDF24 Creator",
    "description": "Free and easy-to-use online/desktop PDF tools that make you more productive",
    "link": "https://tools.pdf24.org/en/creator",
    "winget": "geeksoftwareGmbH.PDF24Creator",
    "foss": false
  },
  "WPFInstallpdfgear": {
    "category": "Document",
    "choco": "pdfgear",
    "content": "PDFgear",
    "description": "PDFgear is a piece of full-featured PDF management software for Windows, macOS, and mobile, and it's completely free to use.",
    "link": "https://www.pdfgear.com/",
    "winget": "PDFgear.PDFgear",
    "foss": false
  },
  "WPFInstallpdfsam": {
    "category": "Document",
    "choco": "pdfsam",
    "content": "PDFsam Basic",
    "description": "PDFsam Basic is a free and open-source tool for splitting, merging, and rotating PDF files.",
    "link": "https://pdfsam.org/",
    "winget": "PDFsam.PDFsam",
    "foss": true
  },
  "WPFInstallplaynite": {
    "category": "Games",
    "choco": "playnite",
    "content": "Playnite",
    "description": "Playnite is an open-source video game library manager with one simple goal: To provide a unified interface for all of your games.",
    "link": "https://playnite.link/",
    "winget": "Playnite.Playnite",
    "foss": true
  },
  "WPFInstallplex": {
    "category": "Selfhosted Tools",
    "choco": "plexmediaserver",
    "content": "Plex Media Server",
    "description": "Plex Media Server is a media server software that allows you to organize and stream your media library. It supports various media formats and offers a wide range of features.",
    "link": "https://www.plex.tv/your-media/",
    "winget": "Plex.PlexMediaServer",
    "foss": false
  },
  "WPFInstallplexdesktop": {
    "category": "Selfhosted Tools",
    "choco": "plex",
    "content": "Plex Desktop",
    "description": "Plex Desktop for Windows is the front end for Plex Media Server.",
    "link": "https://www.plex.tv",
    "winget": "Plex.Plex",
    "foss": false
  },
  "WPFInstallposh": {
    "category": "Development",
    "choco": "oh-my-posh",
    "content": "Oh My Posh (Prompt)",
    "description": "Oh My Posh is a cross-platform prompt theme engine for any shell.",
    "link": "https://ohmyposh.dev/",
    "winget": "JanDeDobbeleer.OhMyPosh",
    "foss": true
  },
  "WPFInstallpowershell": {
    "category": "Microsoft Tools",
    "choco": "powershell-core",
    "content": "PowerShell",
    "description": "PowerShell is a task automation framework and scripting language designed for system administrators, offering powerful command-line capabilities.",
    "link": "https://github.com/PowerShell/PowerShell",
    "winget": "Microsoft.PowerShell",
    "foss": true
  },
  "WPFInstallpowertoys": {
    "category": "Microsoft Tools",
    "choco": "powertoys",
    "content": "PowerToys",
    "description": "PowerToys is a set of utilities for power users to enhance productivity, featuring tools like FancyZones, PowerRename, and more.",
    "link": "https://github.com/microsoft/PowerToys",
    "winget": "Microsoft.PowerToys",
    "foss": true
  },
  "WPFInstallprismlauncher": {
    "category": "Games",
    "choco": "prismlauncher",
    "content": "Prism Launcher",
    "description": "Prism Launcher is an open-source Minecraft launcher with the ability to manage multiple instances, accounts, and mods.",
    "link": "https://prismlauncher.org/",
    "winget": "PrismLauncher.PrismLauncher",
    "foss": true
  },
  "WPFInstallprocesslasso": {
    "category": "Utilities",
    "choco": "plasso",
    "content": "Process Lasso",
    "description": "Process Lasso is a system optimization and automation tool that improves system responsiveness and stability by adjusting process priorities and CPU affinities.",
    "link": "https://bitsum.com/",
    "winget": "BitSum.ProcessLasso",
    "foss": false
  },
  "WPFInstallprotonauth": {
    "category": "Utilities",
    "choco": "protonauth",
    "content": "Proton Authenticator",
    "description": "2FA app from Proton to securely sync and backup 2FA codes.",
    "link": "https://proton.me/authenticator",
    "winget": "Proton.ProtonAuthenticator",
    "foss": true
  },
  "WPFInstallprotonmail": {
    "category": "Communications",
    "choco": "protonmail",
    "content": "Proton Mail",
    "description": "Proton Mail is an end-to-end encrypted email service by Proton, protecting your privacy with zero-access encryption.",
    "link": "https://proton.me/mail",
    "winget": "Proton.ProtonMail",
    "foss": true
  },
  "WPFInstallprotondrive": {
    "category": "Utilities",
    "choco": "protondrive",
    "content": "Proton Drive",
    "description": "Proton Drive is an end-to-end encrypted Swiss vault for your files that protects your data.",
    "link": "https://proton.me/drive",
    "winget": "Proton.ProtonDrive",
    "foss": true
  },
  "WPFInstallprotonpass": {
    "category": "Utilities",
    "choco": "protonpass",
    "content": "Proton Pass",
    "description": "Proton Pass is a cloud-based password manager with end-to-end encryption and unique email aliases.",
    "link": "https://proton.me/pass",
    "winget": "Proton.ProtonPass",
    "foss": true
  },
  "WPFInstallprotonvpn": {
    "category": "Pro Tools",
    "choco": "protonvpn",
    "content": "Proton VPN",
    "description": "Proton VPN is a no-logs VPN service that protects your privacy online with features like Secure Core and Tor over VPN.",
    "link": "https://protonvpn.com/",
    "winget": "Proton.ProtonVPN",
    "foss": true
  },
  "WPFInstallprocessmonitor": {
    "category": "Microsoft Tools",
    "choco": "procexp",
    "content": "Process Monitor",
    "description": "SysInternals Process Monitor is an advanced monitoring tool that shows real-time file system, registry, and process/thread activity.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
    "winget": "Microsoft.Sysinternals.ProcessMonitor",
    "foss": false
  },
  "WPFInstallputty": {
    "category": "Pro Tools",
    "choco": "putty",
    "content": "PuTTY",
    "description": "PuTTY is a free and open-source terminal emulator, serial console, and network file transfer application. It supports various network protocols such as SSH, Telnet, and SCP.",
    "link": "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
    "winget": "PuTTY.PuTTY",
    "foss": true
  },
  "WPFInstallpython3": {
    "category": "Development",
    "choco": "python",
    "content": "Python3",
    "description": "Python is a versatile programming language used for web development, data analysis, artificial intelligence, and more.",
    "link": "https://www.python.org/",
    "winget": "Python.Python.3.14",
    "foss": true
  },
  "WPFInstallqbittorrent": {
    "category": "Utilities",
    "choco": "qbittorrent",
    "content": "qBittorrent",
    "description": "qBittorrent is a free and open-source BitTorrent client that aims to provide a feature-rich and lightweight alternative to other torrent clients.",
    "link": "https://www.qbittorrent.org/",
    "winget": "qBittorrent.qBittorrent",
    "foss": true
  },
  "WPFInstallqtox": {
    "category": "Communications",
    "choco": "qtox",
    "content": "QTox",
    "description": "QTox is a free and open-source messaging app that prioritizes user privacy and security in its design.",
    "link": "https://qtox.github.io/",
    "winget": "Tox.qTox",
    "foss": true
  },
  "WPFInstallrevo": {
    "category": "Utilities",
    "choco": "revo-uninstaller",
    "content": "Revo Uninstaller",
    "description": "Revo Uninstaller is an advanced uninstaller tool that helps you remove unwanted software and clean up your system.",
    "link": "https://www.revouninstaller.com/",
    "winget": "RevoUninstaller.RevoUninstaller",
    "foss": false
  },
  "WPFInstallWiseProgramUninstaller": {
    "category": "Utilities",
    "choco": "na",
    "content": "Wise Program Uninstaller (WiseCleaner)",
    "description": "Wise Program Uninstaller is the perfect solution for uninstalling Windows programs, allowing you to uninstall applications quickly and completely using its simple and user-friendly interface.",
    "link": "https://www.wisecleaner.com/wise-program-uninstaller.html",
    "winget": "WiseCleaner.WiseProgramUninstaller",
    "foss": false
  },
  "WPFInstallrufus": {
    "category": "Utilities",
    "choco": "rufus",
    "content": "Rufus Imager",
    "description": "Rufus is a utility that helps format and create bootable USB drives, such as USB keys or pen drives.",
    "link": "https://rufus.ie/",
    "winget": "Rufus.Rufus",
    "foss": true
  },
  "WPFInstallrustlang": {
    "category": "Development",
    "choco": "rust",
    "content": "Rust",
    "description": "Rust is a programming language designed for safety and performance, particularly focused on systems programming.",
    "link": "https://www.rust-lang.org/",
    "winget": "Rustlang.Rust.MSVC",
    "foss": true
  },
  "WPFInstallsdio": {
    "category": "Utilities",
    "choco": "sdio",
    "content": "Snappy Driver Installer Origin",
    "description": "Snappy Driver Installer Origin is a free and open-source driver updater with a vast driver database for Windows.",
    "link": "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
    "winget": "GlennDelahoy.SnappyDriverInstallerOrigin",
    "foss": true
  },
  "WPFInstallsharex": {
    "category": "Multimedia Tools",
    "choco": "sharex",
    "content": "ShareX (Screenshots)",
    "description": "ShareX is a free and open-source screen capture and file sharing tool. It supports various capture methods and offers advanced features for editing and sharing screenshots.",
    "link": "https://getsharex.com/",
    "winget": "ShareX.ShareX",
    "foss": true
  },
  "WPFInstallnilesoftShell": {
    "category": "Utilities",
    "choco": "nilesoft-shell",
    "content": "Nilesoft Shell",
    "description": "Shell is an expanded context menu tool that adds extra functionality and customization options to the Windows context menu.",
    "link": "https://nilesoft.org/",
    "winget": "Nilesoft.Shell",
    "foss": false
  },
  "WPFInstallsysteminformer": {
    "category": "Development",
    "choco": "systeminformer",
    "content": "System Informer",
    "description": "A free, powerful, multi-purpose tool that helps you monitor system resources, debug software and detect malware.",
    "link": "https://systeminformer.com/",
    "winget": "WinsiderSS.SystemInformer",
    "foss": true
  },
  "WPFInstallsignal": {
    "category": "Communications",
    "choco": "signal",
    "content": "Signal",
    "description": "Signal is a privacy-focused messaging app that offers end-to-end encryption for secure and private communication.",
    "link": "https://signal.org/",
    "winget": "OpenWhisperSystems.Signal",
    "foss": true
  },
  "WPFInstallsignalrgb": {
    "category": "Utilities",
    "choco": "na",
    "content": "SignalRGB",
    "description": "SignalRGB lets you control and sync your favorite RGB devices with one free application.",
    "link": "https://www.signalrgb.com/",
    "winget": "WhirlwindFX.SignalRgb",
    "foss": false
  },
  "WPFInstallsimplenote": {
    "category": "Document",
    "choco": "simplenote",
    "content": "Simplenote",
    "description": "Simplenote is an easy way to keep notes, lists, ideas and more.",
    "link": "https://simplenote.com/",
    "winget": "Automattic.Simplenote",
    "foss": true
  },
  "WPFInstallsimplewall": {
    "category": "Pro Tools",
    "choco": "simplewall",
    "content": "Simplewall",
    "description": "Simplewall is a free and open-source firewall application for Windows. It allows users to control and manage the inbound and outbound network traffic of applications.",
    "link": "https://github.com/henrypp/simplewall",
    "winget": "Henry++.simplewall",
    "foss": true
  },
  "WPFInstallslack": {
    "category": "Communications",
    "choco": "slack",
    "content": "Slack",
    "description": "Slack is a collaboration hub that connects teams and facilitates communication through channels, messaging, and file sharing.",
    "link": "https://slack.com/",
    "winget": "SlackTechnologies.Slack",
    "foss": false
  },
  "WPFInstallstartallback": {
    "category": "Utilities",
    "choco": "StartAllBack",
    "content": "StartAllBack",
    "description": "StartAllBack restores and improves Windows taskbar, Start menu, File Explorer, and shell UI behavior.",
    "link": "https://www.startallback.com/",
    "winget": "StartIsBack.StartAllBack",
    "foss": false
  },
  "WPFInstallsteam": {
    "category": "Games",
    "choco": "steam-client",
    "content": "Steam",
    "description": "Steam is a digital distribution platform for purchasing and playing video games, offering multiplayer gaming, video streaming, and more.",
    "link": "https://store.steampowered.com/about/",
    "winget": "Valve.Steam",
    "foss": false
  },
  "WPFInstallsublimetext": {
    "category": "Development",
    "choco": "sublimetext4",
    "content": "Sublime Text",
    "description": "Sublime Text is a sophisticated text editor for code, markup, and prose.",
    "link": "https://www.sublimetext.com/",
    "winget": "SublimeHQ.SublimeText.4",
    "foss": false
  },
  "WPFInstallsumatra": {
    "category": "Document",
    "choco": "sumatrapdf",
    "content": "Sumatra PDF",
    "description": "Sumatra PDF is a lightweight and fast PDF viewer with minimalistic design.",
    "link": "https://www.sumatrapdfreader.org/free-pdf-reader.html",
    "winget": "SumatraPDF.SumatraPDF",
    "foss": true
  },
  "WPFInstallsunshine": {
    "category": "Selfhosted Tools",
    "choco": "sunshine",
    "content": "Sunshine/GameStream Server",
    "description": "Sunshine is a GameStream server that allows you to remotely play PC games on Android devices, offering low-latency streaming.",
    "link": "https://github.com/LizardByte/Sunshine",
    "winget": "LizardByte.Sunshine",
    "foss": true
  },
  "WPFInstalltcpview": {
    "category": "Microsoft Tools",
    "choco": "tcpview",
    "content": "TCPView",
    "description": "SysInternals TCPView is a network monitoring tool that displays a detailed list of all TCP and UDP endpoints on your system.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
    "winget": "Microsoft.Sysinternals.TCPView",
    "foss": false
  },
  "WPFInstallteams": {
    "category": "Communications",
    "choco": "microsoft-teams",
    "content": "Teams",
    "description": "Microsoft Teams is a collaboration platform that integrates with Office 365 and offers chat, video conferencing, file sharing, and more.",
    "link": "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
    "winget": "Microsoft.Teams",
    "foss": false
  },
  "WPFInstallteamviewer": {
    "category": "Utilities",
    "choco": "teamviewer9",
    "content": "TeamViewer",
    "description": "TeamViewer is a popular remote access and support software that allows you to connect to and control remote devices.",
    "link": "https://www.teamviewer.com/",
    "winget": "TeamViewer.TeamViewer",
    "foss": false
  },
  "WPFInstallteamspeak3": {
    "category": "Communications",
    "choco": "teamspeak",
    "content": "TeamSpeak 3",
    "description": "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your teammates cross-platform with military-grade security, lag-free performance & unparalleled reliability and uptime.",
    "link": "https://www.teamspeak.com/",
    "winget": "TeamSpeakSystems.TeamSpeakClient",
    "foss": false
  },
  "WPFInstalltelegram": {
    "category": "Communications",
    "choco": "telegram",
    "content": "Telegram",
    "description": "Telegram is a cloud-based instant messaging app known for its security features, speed, and simplicity.",
    "link": "https://telegram.org/",
    "winget": "Telegram.TelegramDesktop",
    "foss": true
  },
  "WPFInstallterminal": {
    "category": "Microsoft Tools",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal",
    "description": "Windows Terminal is a modern, fast, and efficient terminal application for command-line users, supporting multiple tabs, panes, and more.",
    "link": "https://aka.ms/terminal",
    "winget": "Microsoft.WindowsTerminal",
    "foss": true
  },
  "WPFInstallthunderbird": {
    "category": "Communications",
    "choco": "thunderbird",
    "content": "Thunderbird",
    "description": "Mozilla Thunderbird is a free and open-source email client, news client, and chat client with advanced features.",
    "link": "https://www.thunderbird.net/",
    "winget": "Mozilla.Thunderbird",
    "foss": true
  },
  "WPFInstallbetterbird": {
    "category": "Communications",
    "choco": "betterbird",
    "content": "Betterbird",
    "description": "Betterbird is a fork of Mozilla Thunderbird with additional features and bugfixes.",
    "link": "https://www.betterbird.eu/",
    "winget": "Betterbird.Betterbird",
    "foss": true
  },
  "WPFInstalltor": {
    "category": "Browsers",
    "choco": "tor-browser",
    "content": "Tor Browser",
    "description": "Tor Browser is designed for anonymous web browsing, utilizing the Tor network to protect user privacy and security.",
    "link": "https://www.torproject.org/",
    "winget": "TorProject.TorBrowser",
    "foss": true
  },
  "WPFInstalltotalcommander": {
    "category": "Utilities",
    "choco": "TotalCommander",
    "content": "Total Commander",
    "description": "Total Commander is a file manager for Windows that provides a powerful and intuitive interface for file management.",
    "link": "https://www.ghisler.com/",
    "winget": "Ghisler.TotalCommander",
    "foss": false
  },
  "WPFInstalltreesize": {
    "category": "Utilities",
    "choco": "treesizefree",
    "content": "TreeSize Free",
    "description": "TreeSize Free is a disk space manager that helps you analyze and visualize the space usage on your drives.",
    "link": "https://www.jam-software.com/treesize_free/",
    "winget": "JAMSoftware.TreeSize.Free",
    "foss": false
  },
  "WPFInstallttaskbar": {
    "category": "Utilities",
    "choco": "translucenttb",
    "content": "TranslucentTB",
    "description": "TranslucentTB is a tool that allows you to customize the transparency of the Windows Taskbar.",
    "link": "https://github.com/TranslucentTB/TranslucentTB",
    "winget": "CharlesMilette.TranslucentTB",
    "foss": true
  },
  "WPFInstallubisoft": {
    "category": "Games",
    "choco": "ubisoft-connect",
    "content": "Ubisoft Connect",
    "description": "Ubisoft Connect is Ubisoft's digital distribution and online gaming service, providing access to Ubisoft's games and services.",
    "link": "https://ubisoftconnect.com/",
    "winget": "Ubisoft.Connect",
    "foss": false
  },
  "WPFInstallungoogled": {
    "category": "Browsers",
    "choco": "ungoogled-chromium",
    "content": "Ungoogled Chromium",
    "description": "Ungoogled Chromium is a version of Chromium without Google's integration for enhanced privacy and control.",
    "link": "https://github.com/Eloston/ungoogled-chromium",
    "winget": "eloston.ungoogled-chromium",
    "foss": true
  },
  "WPFInstallunity": {
    "category": "Development",
    "choco": "unityhub",
    "content": "Unity Game Engine",
    "description": "Unity is a powerful game development platform for creating 2D, 3D, augmented reality, and virtual reality games.",
    "link": "https://unity.com/",
    "winget": "Unity.UnityHub",
    "foss": false
  },
  "WPFInstalleverything": {
    "category": "Utilities",
    "choco": "everything",
    "content": "Everything",
    "description": "Everything is a search engine that locates files and folders by filename instantly for Windows. Unlike Windows search Everything initially displays every file and folder on your computer (hence the name Everything). You type in a search filter to limit what files and folders are displayed.",
    "link": "https://www.voidtools.com/",
    "winget": "voidtools.Everything",
    "foss": false
  },
  "WPFInstallvc2015_32": {
    "category": "Microsoft Tools",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 32-bit",
    "description": "Visual C++ 2015-2022 32-bit redistributable package installs runtime components of Visual C++ libraries required to run 32-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x86",
    "foss": false
  },
  "WPFInstallvc2015_64": {
    "category": "Microsoft Tools",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 64-bit",
    "description": "Visual C++ 2015-2022 64-bit redistributable package installs runtime components of Visual C++ libraries required to run 64-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x64",
    "foss": false
  },
  "WPFInstallventoy": {
    "category": "Pro Tools",
    "choco": "ventoy",
    "content": "Ventoy",
    "description": "Ventoy is an open-source tool for creating bootable USB drives. It supports multiple ISO files on a single USB drive, making it a versatile solution for installing operating systems.",
    "link": "https://www.ventoy.net/",
    "winget": "Ventoy.Ventoy",
    "foss": true
  },
  "WPFInstallvesktop": {
    "category": "Communications",
    "choco": "na",
    "content": "Vesktop",
    "description": "A cross platform electron-based desktop app aiming to give you a snappier Discord experience with Vencord pre-installed.",
    "link": "https://github.com/Vencord/Vesktop",
    "winget": "Vencord.Vesktop",
    "foss": true
  },
  "WPFInstallviber": {
    "category": "Communications",
    "choco": "viber",
    "content": "Viber",
    "description": "Viber is a free messaging and calling app with features like group chats, video calls, and more.",
    "link": "https://www.viber.com/",
    "winget": "Rakuten.Viber",
    "foss": false
  },
  "WPFInstallvisualstudio2022": {
    "category": "Development",
    "choco": "visualstudio2022community",
    "content": "Visual Studio 2022",
    "description": "Visual Studio 2022 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.2022.Community",
    "foss": false
  },
  "WPFInstallvisualstudio2026": {
    "category": "Development",
    "choco": "visualstudio2026community",
    "content": "Visual Studio 2026",
    "description": "Visual Studio 2026 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.Community",
    "foss": false
  },
  "WPFInstallvivaldi": {
    "category": "Browsers",
    "choco": "vivaldi",
    "content": "Vivaldi",
    "description": "Vivaldi is a highly customizable web browser with a focus on user personalization and productivity features.",
    "link": "https://vivaldi.com/",
    "winget": "Vivaldi.Vivaldi",
    "foss": false
  },
  "WPFInstallvlc": {
    "category": "Multimedia Tools",
    "choco": "vlc",
    "content": "VLC (Video Player)",
    "description": "VLC Media Player is a free and open-source multimedia player that supports a wide range of audio and video formats. It is known for its versatility and cross-platform compatibility.",
    "link": "https://www.videolan.org/vlc/",
    "winget": "VideoLAN.VLC",
    "foss": true
  },
  "WPFInstallvrdesktopstreamer": {
    "category": "Games",
    "choco": "na",
    "content": "Virtual Desktop Streamer",
    "description": "Virtual Desktop Streamer is a tool that allows you to stream your desktop screen to VR devices.",
    "link": "https://www.vrdesktop.net/",
    "winget": "VirtualDesktop.Streamer",
    "foss": false
  },
  "WPFInstallvscode": {
    "category": "Development",
    "choco": "vscode",
    "content": "VS Code",
    "description": "Visual Studio Code is a free, open-source code editor with support for multiple programming languages.",
    "link": "https://code.visualstudio.com/",
    "winget": "Microsoft.VisualStudioCode",
    "foss": true
  },
  "WPFInstallvscodium": {
    "category": "Development",
    "choco": "vscodium",
    "content": "VS Codium",
    "description": "VSCodium is a community-driven, freely-licensed binary distribution of Microsoft's VS Code.",
    "link": "https://vscodium.com/",
    "winget": "VSCodium.VSCodium",
    "foss": true
  },
  "WPFInstallwaterfox": {
    "category": "Browsers",
    "choco": "waterfox",
    "content": "Waterfox",
    "description": "Waterfox is a fast, privacy-focused web browser based on Firefox, designed to preserve user choice and privacy.",
    "link": "https://www.waterfox.net/",
    "winget": "Waterfox.Waterfox",
    "foss": true
  },
  "WPFInstallwhatsapp": {
    "category": "Communications",
    "choco": "na",
    "content": "WhatsApp Desktop",
    "description": "WhatsApp Desktop is the official Windows desktop messaging app from Meta, distributed through the Microsoft Store.",
    "link": "https://apps.microsoft.com/detail/9nksqgp7f2nh",
    "winget": "msstore:9NKSQGP7F2NH",
    "foss": false
  },
  "WPFInstallwingetui": {
    "category": "Utilities",
    "choco": "wingetui",
    "content": "UniGetUI",
    "description": "UniGetUI is a GUI for WinGet, Chocolatey, and other Windows CLI package managers.",
    "link": "https://devolutions.net/unigetui/",
    "winget": "Devolutions.UniGetUI",
    "foss": true
  },
  "WPFInstallwinrar": {
    "category": "Utilities",
    "choco": "winrar",
    "content": "WinRAR",
    "description": "WinRAR is a powerful archive manager that allows you to create, manage, and extract compressed files.",
    "link": "https://www.win-rar.com/",
    "winget": "RARLab.WinRAR",
    "foss": false
  },
  "WPFInstallwinscp": {
    "category": "Pro Tools",
    "choco": "winscp",
    "content": "WinSCP",
    "description": "WinSCP is a popular open-source SFTP, FTP, and SCP client for Windows. It allows secure file transfers between a local and a remote computer.",
    "link": "https://winscp.net/",
    "winget": "WinSCP.WinSCP",
    "foss": true
  },
  "WPFInstallwireguard": {
    "category": "Pro Tools",
    "choco": "wireguard",
    "content": "WireGuard",
    "description": "WireGuard is a fast and modern VPN (Virtual Private Network) protocol. It aims to be simpler and more efficient than other VPN protocols, providing secure and reliable connections.",
    "link": "https://www.wireguard.com/",
    "winget": "WireGuard.WireGuard",
    "foss": true
  },
  "WPFInstallwireshark": {
    "category": "Pro Tools",
    "choco": "wireshark",
    "content": "Wireshark",
    "description": "Wireshark is a widely-used open-source network protocol analyzer. It allows users to capture and analyze network traffic in real-time, providing detailed insights into network activities.",
    "link": "https://www.wireshark.org/",
    "winget": "WiresharkFoundation.Wireshark",
    "foss": true
  },
  "WPFInstallwiztree": {
    "category": "Utilities",
    "choco": "wiztree",
    "content": "WizTree",
    "description": "WizTree is a fast disk space analyzer that helps you quickly find the files and folders consuming the most space on your hard drive.",
    "link": "https://wiztreefree.com/",
    "winget": "AntibodySoftware.WizTree",
    "foss": false
  },
  "WPFInstallxeheditor": {
    "category": "Utilities",
    "choco": "HxD",
    "content": "HxD Hex Editor",
    "description": "HxD is a free hex editor that allows you to edit, view, search, and analyze binary files.",
    "link": "https://mh-nexus.de/en/hxd/",
    "winget": "MHNexus.HxD",
    "foss": false
  },
  "WPFInstallxournal": {
    "category": "Document",
    "choco": "xournalplusplus",
    "content": "Xournal++",
    "description": "Xournal++ is an open-source handwriting notetaking software with PDF annotation capabilities.",
    "link": "https://xournalpp.github.io/",
    "winget": "Xournal++.Xournal++",
    "foss": true
  },
  "WPFInstallyarn": {
    "category": "Development",
    "choco": "yarn",
    "content": "Yarn",
    "description": "Yarn is a fast, reliable, and secure dependency management tool for JavaScript projects.",
    "link": "https://yarnpkg.com/",
    "winget": "Yarn.Yarn",
    "foss": true
  },
  "WPFInstallzoom": {
    "category": "Communications",
    "choco": "zoom",
    "content": "Zoom",
    "description": "Zoom is a popular video conferencing and web conferencing service for online meetings, webinars, and collaborative projects.",
    "link": "https://zoom.us/",
    "winget": "Zoom.Zoom",
    "foss": false
  },
  "WPFInstalluv": {
    "category": "Development",
    "choco": "uv",
    "content": "uv",
    "description": "uv is a fast Python package and project manager written in Rust.",
    "link": "https://docs.astral.sh/uv/getting-started/installation/",
    "winget": "astral-sh.uv",
    "foss": true
  },
  "WPFInstalltightvnc": {
    "category": "Utilities",
    "choco": "TightVNC",
    "content": "TightVNC",
    "description": "TightVNC is a free and open-source remote desktop software that lets you access and control a computer over the network. With its intuitive interface, you can interact with the remote screen as if you were sitting in front of it. You can open files, launch applications, and perform other actions on the remote desktop almost as if you were physically there.",
    "link": "https://www.tightvnc.com/",
    "winget": "GlavSoft.TightVNC",
    "foss": true
  },
  "WPFInstallglazewm": {
    "category": "Utilities",
    "choco": "glazewm",
    "content": "GlazeWM",
    "description": "GlazeWM is a tiling window manager for Windows inspired by i3 and Polybar.",
    "link": "https://github.com/glzr-io/glazewm",
    "winget": "glzr-io.glazewm",
    "foss": true
  },
  "WPFInstallOverwolf": {
    "category": "Games",
    "choco": "overwolf",
    "content": "Overwolf",
    "description": "Popular platform for game overlays and companion apps (mod managers, trackers, etc.), widely used by gamers.",
    "link": "https://www.overwolf.com/app/overwolf-curseforge",
    "winget": "Overwolf.CurseForge",
    "foss": false
  },
  "WPFInstallOFGB": {
    "category": "Utilities",
    "choco": "ofgb",
    "content": "OFGB (Oh Frick Go Back)",
    "description": "GUI Tool to remove ads from various places around Windows 11",
    "link": "https://github.com/xM4ddy/OFGB",
    "winget": "xM4ddy.OFGB",
    "foss": true
  },
  "WPFInstallZenBrowser": {
    "category": "Browsers",
    "choco": "zen-browser",
    "content": "Zen Browser",
    "description": "The modern, privacy-focused, performance-driven browser built on Firefox.",
    "link": "https://zen-browser.app/",
    "winget": "Zen-Team.Zen-Browser",
    "foss": true
  },
  "WPFInstallZed": {
    "category": "Development",
    "choco": "zed",
    "content": "Zed",
    "description": "Zed is a modern, high-performance code editor designed from the ground up for speed and collaboration.",
    "link": "https://zed.dev/",
    "winget": "ZedIndustries.Zed",
    "foss": true
  },
  "WPFInstallzotero": {
    "category": "Document",
    "choco": "zotero",
    "content": "Zotero",
    "description": "Zotero is a free, easy-to-use tool to help you collect, organize, cite, and share your research materials.",
    "link": "https://www.zotero.org/",
    "winget": "DigitalScholar.Zotero",
    "foss": true
  },
  "WPFInstalldeskflow": {
    "category": "Utilities",
    "choco": "deskflow",
    "content": "Deskflow",
    "description": "Deskflow is a free and open-source software KVM that lets you share a single keyboard and mouse across multiple computers.",
    "link": "https://github.com/deskflow/deskflow",
    "winget": "Deskflow.Deskflow",
    "foss": true
  },
  "WPFInstallRuby": {
    "category": "Development",
    "choco": "ruby",
    "winget": "RubyInstallerTeam.Ruby.4.0",
    "description": "A Ruby language execution environment with a MSYS2 installation.",
    "content": "Ruby",
    "link": "https://rubyinstaller.org/",
    "foss": true
  },
  "WPFInstallLua": {
    "category": "Development",
    "choco": "lua",
    "winget": "rjpcomputing.luaforwindows",
    "description": "A 'batteries included environment' for the Lua scripting language on Windows.",
    "content": "Lua",
    "link": "https://github.com/rjpcomputing/luaforwindows",
    "foss": true
  }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
  "WPFInstall": {
    "Content": "安装/升级所选应用",
    "Category": "____操作",
    "Type": "Button",
    "Order": "1",
    "Description": "安装或升级你勾选的应用"
  },
  "WPFUninstall": {
    "Content": "卸载所选应用",
    "Category": "____操作",
    "Type": "Button",
    "Order": "2",
    "Description": "卸载你勾选的应用"
  },
  "WPFInstallUpgrade": {
    "Content": "升级全部应用",
    "Category": "____操作",
    "Type": "Button",
    "Order": "3",
    "Description": "将已安装应用升级到最新版本"
  },
  "WingetRadioButton": {
    "Content": "WinGet",
    "Category": "__包管理器",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "使用 Winget 作为包管理器"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey",
    "Category": "__包管理器",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "使用 Chocolatey 作为包管理器"
  },
  "WPFCollapseAllCategories": {
    "Content": "收起全部分类",
    "Category": "__选择",
    "Type": "Button",
    "Order": "1",
    "Description": "收起所有应用分类"
  },
  "WPFExpandAllCategories": {
    "Content": "展开全部分类",
    "Category": "__选择",
    "Type": "Button",
    "Order": "2",
    "Description": "展开所有应用分类"
  },
  "WPFClearInstallSelection": {
    "Content": "清空选择",
    "Category": "__选择",
    "Type": "Button",
    "Order": "3",
    "Description": "清空已选择的应用"
  },
  "WPFGetInstalled": {
    "Content": "获取已安装",
    "Category": "__选择",
    "Type": "Button",
    "Order": "4",
    "Description": "显示已安装的应用"
  },
  "WPFselectedAppsButton": {
    "Content": "已选应用：0",
    "Category": "__选择",
    "Type": "Button",
    "Order": "5",
    "Description": "显示已选择的应用"
  },
  "WPFInstallFOSSInfo": {
    "Content": "自由与开源软件",
    "Category": "__选择",
    "Type": "Note",
    "Order": "0",
    "Description": "说明应用条目上的 #FOSS 标签"
  }
}
'@ | ConvertFrom-Json
$sync.configs.appx = @'
{
  "WPFAppxMicrosoft_WindowsFeedbackHub": {
    "Category": "Microsoft Apps",
    "Content": "Feedback Hub",
    "Description": "Allows users to submit bug reports, feature suggestions, and diagnostic data directly to Microsoft.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsFeedbackHub",
    "StoreId": "9NBLGGH4R32N"
  },
  "WPFAppxMicrosoft_GetHelp": {
    "Category": "Microsoft Apps",
    "Content": "Get Help",
    "Description": "Provides access to automated troubleshooting guides, support documentation, and direct Microsoft customer assistance.",
    "Panel": "0",
    "PackageId": "Microsoft.GetHelp",
    "StoreId": "9PKDZBMV1H3T"
  },
  "WPFAppxMicrosoft_OutlookForWindows": {
    "Category": "Microsoft Apps",
    "Content": "Outlook for Windows",
    "Description": "Provides modern email management, calendar scheduling, and contact organization features.",
    "Panel": "0",
    "PackageId": "Microsoft.OutlookForWindows",
    "StoreId": "9NRX63209R7B"
  },
  "WPFAppxMSTeams": {
    "Category": "Microsoft Apps",
    "Content": "Microsoft Teams",
    "Description": "Facilitates instant messaging, video conferencing, file sharing, and workspace collaboration.",
    "Panel": "0",
    "PackageId": "MSTeams",
    "StoreId": "XP8BT8DW290MPQ"
  },
  "WPFAppxClipchamp_Clipchamp": {
    "Category": "Utilities & Productivity",
    "Content": "Clipchamp",
    "Description": "Provides a user-friendly video editor with built-in templates, effects, and timeline editing tools.",
    "Panel": "0",
    "PackageId": "Clipchamp.Clipchamp",
    "StoreId": "9P1J8S7CCWWT"
  },
  "WPFAppxMicrosoft_MicrosoftOfficeHub": {
    "Category": "Microsoft Apps",
    "Content": "Microsoft 365",
    "Description": "Serves as a centralized launcher and dashboard for accessing cloud-based Microsoft 365 apps and recent documents.",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftOfficeHub",
    "StoreId": "9WZDNCRD29V9"
  },
  "WPFAppxMicrosoft_ZuneMusic": {
    "Category": "Utilities & Productivity",
    "Content": "Media Player",
    "Description": "Plays local audio and video files with modern playlist management and casting capabilities.",
    "Panel": "0",
    "PackageId": "Microsoft.ZuneMusic",
    "StoreId": "9WZDNCRFJ3PT"
  },
  "WPFAppxMicrosoft_BingSearch": {
    "Category": "Bing & Web Services",
    "Content": "Bing Search",
    "Description": "Integrates Microsoft Bing search capabilities and web services directly into the operating system.",
    "Panel": "1",
    "PackageId": "Microsoft.BingSearch",
    "StoreId": "9NZBF4GT040C"
  },
  "WPFAppxMicrosoftCorporationII_QuickAssist": {
    "Category": "Utilities & Productivity",
    "Content": "Quick Assist",
    "Description": "Enables secure remote technical support and screen sharing over an internet connection.",
    "Panel": "0",
    "PackageId": "MicrosoftCorporationII.QuickAssist",
    "StoreId": "9P7BP5VNWKX5"
  },
  "WPFAppxMicrosoft_WindowsDevHome": {
    "Category": "Developer Tools",
    "Content": "Dev Home",
    "Description": "Provides a specialized dashboard for software developer environment setups, repository syncing, and hardware widgets.",
    "Panel": "1",
    "PackageId": "Microsoft.Windows.DevHome",
    "StoreId": "9N8MHTPHNGVV"
  },
  "WPFAppxMicrosoft_WindowsCrossDevice": {
    "Category": "Microsoft Ecosystem",
    "Content": "Mobile Devices",
    "Description": "Manages system-level background connectivity with paired mobile devices. Removing this may disable cross-device features such as phone screen mirroring, file transfer, and mobile hotspot handoff integrated into Windows Settings.",
    "Panel": "0",
    "PackageId": "MicrosoftWindows.CrossDevice",
    "StoreId": "9NTXGKQ8P7N0"
  },
  "WPFAppxMicrosoft_Todos": {
    "Category": "Utilities & Productivity",
    "Content": "To Do",
    "Description": "Creates, tracks, and synchronizes personal tasks, smart lists, and daily reminders.",
    "Panel": "0",
    "PackageId": "Microsoft.Todos",
    "StoreId": "9NBLGGH5R558"
  },
  "WPFAppxMicrosoft_PowerAutomateDesktop": {
    "Category": "Developer Tools",
    "Content": "Power Automate",
    "Description": "Automates repetitive workflows and desktop tasks using low-code visual scripting.",
    "Panel": "1",
    "PackageId": "Microsoft.PowerAutomateDesktop",
    "StoreId": "9NFTCH6J7FHV"
  },
  "WPFAppxMicrosoft_YourPhone": {
    "Category": "Microsoft Ecosystem",
    "Content": "Phone Link",
    "Description": "Synchronizes text messages, phone notifications, photos, and calls from a mobile device to the desktop.",
    "Panel": "0",
    "PackageId": "Microsoft.YourPhone",
    "StoreId": "9NMPJ99VJBWV"
  },
  "WPFAppxMicrosoft_MicrosoftStickyNotes": {
    "Category": "Utilities & Productivity",
    "Content": "Sticky Notes",
    "Description": "Creates quick, floating text notes on the desktop that automatically sync across devices.",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftStickyNotes",
    "StoreId": "9NBLGGH4QGHW"
  },
  "WPFAppxMicrosoft_WindowsSoundRecorder": {
    "Category": "Utilities & Productivity",
    "Content": "Sound Recorder",
    "Description": "Records and trims live audio inputs with simple microphone adjustment controls.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsSoundRecorder",
    "StoreId": "9WZDNCRFHWKN"
  },
  "WPFAppxMicrosoft_WindowsAlarms": {
    "Category": "Utilities & Productivity",
    "Content": "Clock",
    "Description": "Features world clocks, alarms, countdown timers, stopwatches, and dedicated focus session tracking.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsAlarms",
    "StoreId": "9WZDNCRFJ3PR"
  },
  "WPFAppxMicrosoft_Paint": {
    "Category": "Utilities & Productivity",
    "Content": "Paint",
    "Description": "Provides built-in digital sketching, basic image editing, and pixel-level graphic manipulation tools.",
    "Panel": "0",
    "PackageId": "Microsoft.Paint",
    "StoreId": "9PCFS5B6T72H"
  },
  "WPFAppxMicrosoft_WindowsNotepad": {
    "Category": "Utilities & Productivity",
    "Content": "Notepad",
    "Description": "Provides a lightweight text editor with multi-tab support for plain text files and code snippets.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsNotepad",
    "StoreId": "9MSMLRH6LZF3"
  },
  "WPFAppxMicrosoft_ScreenSketch": {
    "Category": "Utilities & Productivity",
    "Content": "Snipping Tool",
    "Description": "Captures screenshots or screen recordings with built-in markup, image cropping, and optical character recognition (OCR).",
    "Panel": "0",
    "PackageId": "Microsoft.ScreenSketch",
    "StoreId": "9MZ95KL8MR0L"
  },
  "WPFAppxMicrosoft_Copilot": {
    "Category": "Bing & Web Services",
    "Content": "Copilot",
    "Description": "Launches the Microsoft AI companion for contextual answers, creative writing assistance, and intelligent web search.",
    "Panel": "1",
    "PackageId": "Microsoft.Copilot",
    "StoreId": "9NHT9RB2F4HD"
  },
  "WPFAppxMicrosoft_WindowsCalculator": {
    "Category": "Utilities & Productivity",
    "Content": "Calculator",
    "Description": "Performs standard arithmetic, scientific operations, programming calculations, and unit conversions.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCalculator",
    "StoreId": "9WZDNCRFHVN5"
  },
  "WPFAppxMicrosoft_WindowsCamera": {
    "Category": "Utilities & Productivity",
    "Content": "Camera",
    "Description": "Captures photographs and records video files via connected webcams or imaging hardware.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCamera",
    "StoreId": "9WZDNCRFJBBG"
  },
  "WPFAppxMicrosoft_WindowsPhotos": {
    "Category": "Utilities & Productivity",
    "Content": "Photos",
    "Description": "Organizes, views, and crops local images with basic color adjustment and album creation tools.",
    "Panel": "0",
    "PackageId": "Microsoft.Windows.Photos",
    "StoreId": "9WZDNCRFJBH4"
  },
  "WPFAppxMicrosoft_BingNews": {
    "Category": "Bing & Web Services",
    "Content": "News",
    "Description": "Aggregates breaking news headlines, personalized article feeds, and world current events.",
    "Panel": "1",
    "PackageId": "Microsoft.BingNews",
    "StoreId": "9WZDNCRFHVFW"
  },
  "WPFAppxMicrosoft_BingWeather": {
    "Category": "Bing & Web Services",
    "Content": "Weather",
    "Description": "Displays local real-time weather tracking, radar maps, and historical meteorological forecasts.",
    "Panel": "1",
    "PackageId": "Microsoft.BingWeather",
    "StoreId": "9WZDNCRFJ3Q2"
  },
  "WPFAppxMicrosoft_GamingApp": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox App",
    "Description": "Serves as the primary gaming library manager, social community interface, and PC Game Pass dashboard.",
    "Panel": "1",
    "PackageId": "Microsoft.GamingApp",
    "StoreId": "9MV0B5HZVK9Z"
  },
  "WPFAppxMicrosoft_XboxGamingOverlay": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Game Bar",
    "Description": "Provides customizable in-game status widgets, audio balancing sliders, system monitoring tools, and gameplay recording.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxGamingOverlay",
    "StoreId": "9NZKPSTSNW4P"
  },
  "WPFAppxMicrosoft_XboxIdentityProvider": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Identity Provider",
    "Description": "Manages Xbox network user authentication and background account validation for connected titles. Warning: removing this may break Microsoft account sign-in for non-Xbox games and apps that rely on this authentication pipeline.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxIdentityProvider",
    "StoreId": "9WZDNCRD1HKW"
  },
  "WPFAppxMicrosoft_XboxSpeechToTextOverlay": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox Speech To Text Overlay",
    "Description": "Provides system-level live accessibility captions and voice-to-text translation for gaming chat networks.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxSpeechToTextOverlay"
  },
  "WPFAppxMicrosoft_Xbox_TCUI": {
    "Category": "Xbox & Gaming",
    "Content": "Xbox TCUI",
    "Description": "Provides core account connection UI modules for single sign-on flows within game titles. Warning: removing this may break Microsoft account authentication in games and apps that do not otherwise require the Xbox app.",
    "Panel": "1",
    "PackageId": "Microsoft.Xbox.TCUI"
  },
  "WPFAppxMicrosoft_StartExperiencesApp": {
    "Category": "Bing & Web Services",
    "Content": "Start Experiences App",
    "Description": "Powers the Windows Widgets board, delivering a personalized feed of news, weather, sports, and finance content.",
    "Panel": "1",
    "PackageId": "Microsoft.StartExperiencesApp",
    "StoreId": "9PC1H9VN18CM"
  },
  "WPFAppxMicrosoft_MicrosoftSolitaireCollection": {
    "Category": "Xbox & Gaming",
    "Content": "Solitaire Collection",
    "Description": "Bundles built-in card game modes including Klondike, Spider, FreeCell, Pyramid, and TriPeaks alongside daily challenges.",
    "Panel": "1",
    "PackageId": "Microsoft.MicrosoftSolitaireCollection"
  }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
  "Google": {
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844",
    "DohTemplate": "https://dns.google/dns-query"
  },
  "Cloudflare": {
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001",
    "DohTemplate": "https://cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002",
    "DohTemplate": "https://security.cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003",
    "DohTemplate": "https://family.cloudflare-dns.com/dns-query"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53",
    "DohTemplate": "https://doh.opendns.com/dns-query"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9",
    "DohTemplate": "https://dns.quad9.net/dns-query"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff",
    "DohTemplate": "https://dns.adguard-dns.com/dns-query"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff",
    "DohTemplate": "https://family.adguard-dns.com/dns-query"
  }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": "安装/启用 .NET Framework（2/3/4）",
    "Description": "启用/安装 Windows 的 .NET Framework 功能组件（常用于运行旧软件/开发环境）。",
    "category": "功能组件",
    "panel": "1",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [

    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/dotnet"
  },
  "WPFFixesNTPPool": {
    "Content": "配置 NTP 时间服务器",
    "Description": "将 Windows 默认时间服务器（time.windows.com）替换为 pool.ntp.org，以提高校时准确性和稳定性。",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNTPPool",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/ntppool"
  },
  "WPFFeatureshyperv": {
    "Content": "启用 Hyper‑V 虚拟化",
    "Description": "启用 Hyper‑V 及其管理工具，用于创建与管理虚拟机（需要硬件虚拟化支持）。",
    "category": "功能组件",
    "panel": "1",
    "feature": [
      "Microsoft-Hyper-V-All"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/hyperv"
  },
  "WPFFeatureslegacymedia": {
    "Content": "启用旧媒体组件（WMP/DirectPlay）",
    "Description": "启用旧版媒体相关组件（Windows Media Player、DirectPlay 等），用于兼容老游戏/老播放器。",
    "category": "功能组件",
    "panel": "1",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [

    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/legacymedia"
  },
  "WPFFeaturewsl": {
    "Content": "启用 WSL（Linux 子系统）",
    "Description": "启用 WSL，让你在 Windows 上运行 Linux 发行版（开发/命令行工具常用）。",
    "category": "功能组件",
    "panel": "1",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [

    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/wsl"
  },
  "WPFFeaturenfs": {
    "Content": "启用 NFS（网络文件系统）",
    "Description": "启用 NFS 客户端/相关组件，用于挂载 NFS 共享（多见于 NAS/Unix/Linux 环境）。",
    "category": "功能组件",
    "panel": "1",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/nfs"
  },
  "WPFFeatureRegBackup": {
    "Content": "启用每日注册表备份任务（00:30）",
    "Description": "创建/启用每日注册表自动备份计划任务（默认 00:30），便于系统故障时回滚。",
    "category": "功能组件",
    "panel": "1",
    "feature": [

    ],
    "InvokeScript": [
      "\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/regbackup"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "启用传统 F8 启动恢复菜单",
    "Description": "启用传统“按 F8 进入高级启动选项”的恢复菜单（对排障更方便）。",
    "category": "功能组件",
    "panel": "1",
    "feature": [

    ],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy legacy"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/enablelegacyrecovery"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "禁用传统 F8 启动恢复菜单",
    "Description": "关闭传统 F8 恢复菜单，恢复为默认快速启动行为。",
    "category": "功能组件",
    "panel": "1",
    "feature": [

    ],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy standard"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/disablelegacyrecovery"
  },
  "WPFFeaturesSandbox": {
    "Content": "启用 Windows Sandbox（沙盒）",
    "Description": "启用 Windows 沙盒：一次性、隔离的临时系统环境，适合测试不可信程序（退出即清空）。",
    "category": "功能组件",
    "panel": "1",
    "feature": [
      "Containers-DisposableClientVM"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/features/sandbox"
  },
  "WPFFeatureInstall": {
    "Content": "安装/启用所选功能",
    "category": "功能组件",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFeatureInstall",
    "link": "https://winutil.christitus.com/code-reference/features/features/install"
  },
  "WPFPanelAutologin": {
    "Content": "设置自动登录",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFPanelAutologin",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/autologin"
  },
  "WPFFixesUpdate": {
    "Content": "重置 Windows 更新组件",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesUpdate",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/update"
  },
  "WPFFixesNetwork": {
    "Content": "重置网络设置",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNetwork",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/network"
  },
  "WPFPanelDISM": {
    "Content": "系统损坏扫描/修复（SFC/DISM）",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSystemRepair",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/dism"
  },
  "WPFFixesWinget": {
    "Content": "重新安装/修复 WinGet",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesWinget",
    "link": "https://winutil.christitus.com/code-reference/features/fixes/winget"
  },
  "WPFPanelComputer": {
    "Content": "计算机管理",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "compmgmt.msc"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/computer"
  },
  "WPFPanelControl": {
    "Content": "控制面板",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "control"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/control"
  },
  "WPFPanelMouse": {
    "Content": "鼠标属性",
    "category": "旧版 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "main.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/mouse"
  },
  "WPFPanelNetwork": {
    "Content": "网络连接",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "ncpa.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/network"
  },
  "WPFPanelPower": {
    "Content": "电源选项",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "powercfg.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/power"
  },
  "WPFPanelPrinter": {
    "Content": "打印机设置",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "Start-Process 'shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}'"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/printer"
  },
  "WPFPanelPrograms": {
    "Content": "程序和功能",
    "category": "旧版 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "appwiz.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/programs"
  },
  "WPFPanelRegion": {
    "Content": "区域设置",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "intl.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/region"
  },
  "WPFPanelSecurity": {
    "Content": "安全与维护",
    "category": "旧版 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "wscui.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/security"
  },
  "WPFPanelSound": {
    "Content": "声音设置",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "mmsys.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/sound"
  },
  "WPFPanelSystem": {
    "Content": "系统属性",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "sysdm.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/system"
  },
  "WPFPanelTimedate": {
    "Content": "日期和时间",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "timedate.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/timedate"
  },
  "WPFPanelFirewall": {
    "Content": "Windows Defender 防火墙",
    "category": "旧版 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "firewall.cpl"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/firewall"
  },
  "WPFPanelRestore": {
    "Content": "系统还原（恢复）",
    "category": "传统控制面板入口",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "rstrui.exe"
    ],
    "link": "https://winutil.christitus.com/code-reference/features/legacy-windows-panels/restore"
  },
  "WPFWinUtilInstallPSProfile": {
    "Content": "安装 CTT PowerShell 配置文件",
    "category": "PowerShell 配置文件",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilInstallPSProfile",
    "link": "https://winutil.christitus.com/code-reference/features/powershell-profile-powershell-7--only/installpsprofile"
  },
  "WPFWinUtilUninstallPSProfile": {
    "Content": "卸载 CTT PowerShell 配置文件",
    "category": "PowerShell 配置文件",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilUninstallPSProfile",
    "link": "https://winutil.christitus.com/code-reference/features/powershell-profile-powershell-7--only/uninstallpsprofile"
  },
  "WPFWinUtilSSHServer": {
    "Content": "启用 OpenSSH Server",
    "category": "远程访问",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSSHServer",
    "link": "https://winutil.christitus.com/code-reference/features/remote-access/sshserver"
  }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksWPBT",
    "WPFTweaksServices",
    "WPFTweaksTelemetry"
  ],
  "Advanced": [
    "WPFTweaksRestorePoint",
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksDisableStoreSearch",
    "WPFTweaksRevertStartMenu",
    "WPFTweaksWidget",
    "WPFTweaksRemoveOneDrive",
    "WPFTweaksWindowsAI",
    "WPFTweaksRightClickMenu"
  ],
  "AppxDefault": [
    "WPFAppxMicrosoft_WindowsFeedbackHub",
    "WPFAppxMicrosoft_GetHelp",
    "WPFAppxMicrosoft_MicrosoftOfficeHub",
    "WPFAppxMicrosoft_WindowsCalculator",
    "WPFAppxClipchamp_Clipchamp",
    "WPFAppxMicrosoft_WindowsAlarms",
    "WPFAppxMicrosoftCorporationII_QuickAssist",
    "WPFAppxMicrosoft_WindowsSoundRecorder",
    "WPFAppxMicrosoft_MicrosoftStickyNotes",
    "WPFAppxMicrosoft_Todos",
    "WPFAppxMicrosoft_MicrosoftSolitaireCollection",
    "WPFAppxMicrosoft_PowerAutomateDesktop",
    "WPFAppxMicrosoft_WindowsDevHome",
    "WPFAppxMicrosoft_BingWeather",
    "WPFAppxMicrosoft_StartExperiencesApp",
    "WPFAppxMicrosoft_BingNews",
    "WPFAppxMicrosoft_Copilot",
    "WPFAppxMicrosoft_BingSearch"
  ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
  "shared": {
    "AppEntryWidth": "220",
    "AppEntryFontSize": "13.2",
    "AppEntryIconSize": "28",
    "AppEntryMargin": "3",
    "AppEntryBorderThickness": "1",
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Arial",
    "HeaderFontSize": "16",
    "HeaderFontFamily": "Consolas, Monaco",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "110",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "ToolTipWidth": "300",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "12",
    "GroupBorderBackgroundColor": "#232629",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Arial",
    "ButtonWidth": "200",
    "ButtonHeight": "25",
    "ConfigTabButtonFontSize": "14",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "CheckboxMouseOverColor": "#999999",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "2"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F7F7F7",
    "AppInstallHighlightedColor": "#CFCFCF",
    "AppInstallSelectedColor": "#C2C2C2",
    "ComboBoxForegroundColor": "#232629",
    "ComboBoxBackgroundColor": "#F7F7F7",
    "LabelboxForegroundColor": "#232629",
    "MainForegroundColor": "#232629",
    "MainBackgroundColor": "#F7F7F7",
    "LabelBackgroundColor": "#F7F7F7",
    "LinkForegroundColor": "#484848",
    "LinkHoverForegroundColor": "#232629",
    "ScrollBarBackgroundColor": "#4A4D52",
    "ScrollBarHoverColor": "#5A5D62",
    "ScrollBarDraggingColor": "#6A6D72",
    "ProgressBarForegroundColor": "#2E77FF",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#F7F7F7",
    "ButtonTweaksBackgroundColor": "#F7F7F7",
    "ButtonConfigBackgroundColor": "#F7F7F7",
    "ButtonUpdatesBackgroundColor": "#F7F7F7",
    "ButtonWin11ISOBackgroundColor": "#F7F7F7",
    "ButtonAppxBackgroundColor": "#F7F7F7",
    "ButtonInstallForegroundColor": "#232629",
    "ButtonTweaksForegroundColor": "#232629",
    "ButtonConfigForegroundColor": "#232629",
    "ButtonUpdatesForegroundColor": "#232629",
    "ButtonWin11ISOForegroundColor": "#232629",
    "ButtonAppxForegroundColor": "#232629",
    "ButtonBackgroundColor": "#F5F5F5",
    "ButtonBackgroundPressedColor": "#1A1A1A",
    "ButtonBackgroundMouseoverColor": "#C2C2C2",
    "ButtonBackgroundSelectedColor": "#F0F0F0",
    "ButtonForegroundColor": "#232629",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#F7F7F7",
    "BorderColor": "#232629",
    "BorderOpacity": "0.2"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#232629",
    "AppInstallHighlightedColor": "#3C3C3C",
    "AppInstallSelectedColor": "#4C4C4C",
    "ComboBoxForegroundColor": "#F7F7F7",
    "ComboBoxBackgroundColor": "#1E3747",
    "LabelboxForegroundColor": "#5BDCFF",
    "MainForegroundColor": "#F7F7F7",
    "MainBackgroundColor": "#232629",
    "LabelBackgroundColor": "#232629",
    "LinkForegroundColor": "#ADD8E6",
    "LinkHoverForegroundColor": "#F7F7F7",
    "ScrollBarBackgroundColor": "#2E3135",
    "ScrollBarHoverColor": "#3B4252",
    "ScrollBarDraggingColor": "#5E81AC",
    "ProgressBarForegroundColor": "#6EFF72",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#222222",
    "ButtonTweaksBackgroundColor": "#333333",
    "ButtonConfigBackgroundColor": "#444444",
    "ButtonUpdatesBackgroundColor": "#555555",
    "ButtonWin11ISOBackgroundColor": "#666666",
    "ButtonAppxBackgroundColor": "#777777",
    "ButtonInstallForegroundColor": "#F7F7F7",
    "ButtonTweaksForegroundColor": "#F7F7F7",
    "ButtonConfigForegroundColor": "#F7F7F7",
    "ButtonUpdatesForegroundColor": "#F7F7F7",
    "ButtonWin11ISOForegroundColor": "#F7F7F7",
    "ButtonAppxForegroundColor": "#F7F7F7",
    "ButtonBackgroundColor": "#1E3747",
    "ButtonBackgroundPressedColor": "#F7F7F7",
    "ButtonBackgroundMouseoverColor": "#3B4252",
    "ButtonBackgroundSelectedColor": "#5E81AC",
    "ButtonForegroundColor": "#F7F7F7",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#2F373D",
    "BorderColor": "#2F373D",
    "BorderOpacity": "0.2"
  }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
  "WPFTweaksActivity": {
    "Content": "禁用活动历史记录",
    "Description": "关闭 Windows 活动历史（时间线），减少对最近打开文件、剪贴板/运行历史等的记录与同步。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/activity"
  },
  "WPFTweaksHiber": {
    "Content": "禁用休眠",
    "Description": "关闭休眠功能并释放 hiberfil.sys 以节省磁盘空间。台式机通常不需要；笔记本若依赖休眠可不要选。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/hiber"
  },
  "WPFTweaksWidget": {
    "Content": "移除小组件",
    "Description": "移除任务栏左下角的小组件及相关组件。",
    "category": "基础优化",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Get-Process *Widget* | Stop-Process\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/widget"
  },
  "WPFTweaksRevertStartMenu": {
    "Content": "恢复旧版开始菜单布局",
    "Description": "恢复 25H2 逐步推送前的旧版开始菜单布局。较新的 Windows 版本不再支持此优化。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\8\\3036241548",
        "Name": "EnabledState",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/revertstartmenu"
  },
  "WPFTweaksDisableStoreSearch": {
    "Content": "禁用 Microsoft Store 搜索结果",
    "Description": "在开始菜单搜索应用时，不再显示 Microsoft Store 推荐结果。",
    "category": "基础优化",
    "panel": "1",
    "InvokeScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
    ],
    "UndoScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablestoresearch"
  },
  "WPFTweaksLocation": {
    "Content": "禁用定位服务",
    "Description": "关闭定位相关权限/服务，阻止系统与应用获取你的地理位置。",
    "category": "基础优化",
    "panel": "1",
    "service": [
      {
        "Name": "lfsvc",
        "StartupType": "Disable",
        "OriginalType": "Manual"
      }
    ],
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Value": "Deny",
        "Type": "String",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/location"
  },
  "WPFTweaksServices": {
    "Content": "将部分服务设为手动启动",
    "Description": "把部分系统服务设为手动启动，并根据内存调整 SvcHostSplitThresholdInKB，可明显减少 svchost.exe 进程数量。",
    "category": "基础优化",
    "panel": "1",
    "service": [
      {
        "Name": "CscService",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      }
    ],
    "InvokeScript": [
      "\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/services"
  },
  "WPFTweaksBraveDebloat": {
    "Content": "Brave 浏览器精简",
    "Description": "对 Brave 做“降打扰”设置：减少推广/遥测/弹窗等（不影响基础浏览）。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveRewardsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveWalletDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveVPNDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveAIChatEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveStatsPingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveNewsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveTalkDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "TorDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveP3AEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "UrlKeyedAnonymizedDataCollectionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "SafeBrowsingExtendedReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "MetricsReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/bravedebloat"
  },
  "WPFTweaksDisableWarningForUnsignedRdp": {
    "Content": "禁用未签名 RDP 文件警告",
    "Description": "关闭新版 Windows 10/11 在启动未签名 RDP 文件时显示的安全警告。仅在你信任这些 RDP 文件来源时使用。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
        "Name": "RedirectionWarningDialogVersion",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
        "Name": "RdpLaunchConsentAccepted",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablewarningforunsignedrdp"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Edge 浏览器精简",
    "Description": "对 Edge 做“降打扰”设置：减少遥测、推荐、弹窗等（不卸载 Edge）。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
        "Name": "1",
        "Value": "ofefcgjbeghpigppfmkologfjadafddi",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DefaultBrowserSettingsCampaignEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/edgedebloat"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "禁用“消费者体验/推荐应用”",
    "Description": "阻止 Windows 自动安装推荐应用/游戏等“消费者内容”，减少系统自带推广。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/consumerfeatures"
  },
  "WPFTweaksTelemetry": {
    "Content": "禁用遥测",
    "Description": "关闭 Microsoft 遥测与部分相关数据收集。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
        "Name": "TailoredExperiencesWithDiagnosticDataEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
        "Name": "HasAccepted",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Input\\TIPC",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitInkCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitTextCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
        "Name": "HarvestContacts",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
        "Name": "AcceptedPrivacyPolicy",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Start_TrackProgs",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Disabled\r\n\r\n      # Disable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Disabled\r\n\r\n      # Disable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')\r\n\r\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Automatic\r\n\r\n      # Enable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Automatic\r\n\r\n      # Enable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/telemetry"
  },
  "WPFTweaksDeliveryOptimization": {
    "Content": "禁用传递优化",
    "Description": "阻止 Windows 使用你的带宽向互联网或局域网内的其他电脑上传更新。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
        "Name": "DODownloadMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deliveryoptimization"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "卸载 Microsoft Edge",
    "Description": "在旧版 Edge 目录创建占位 MicrosoftEdge.exe，以解除 Windows 对官方卸载程序的限制，并执行系统级卸载。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $Path = Resolve-Path -Path \"$Env:ProgramFiles (x86)\\Microsoft\\Edge\\Application\\*\\Installer\\setup.exe\" | Select-Object -Last 1\r\n\r\n      if (Test-Path $Path) {\r\n          New-Item -Path \"$Env:SystemRoot\\SystemApps\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\MicrosoftEdge.exe\" -Force\r\n          Start-Process -FilePath $Path -ArgumentList \"--uninstall --system-level --force-uninstall --delete-profile\" -Wait\r\n          Write-Host \"Microsoft Edge was removed\"\r\n      } else {\r\n          Write-Host \"Microsoft Edge is not installed\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing Microsoft Edge...\"\r\n      winget install Microsoft.Edge --source winget\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeedge"
  },
  "WPFTweaksDisableBitLocker": {
    "Content": "禁用 BitLocker",
    "Description": "禁用 BitLocker 驱动器加密。操作前请确认已保存恢复密钥。",
    "category": "基础优化",
    "panel": "1",
    "InvokeScript": [
      "Disable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "UndoScript": [
      "Enable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disablebitlocker"
  },
  "WPFTweaksUTC": {
    "Content": "时间改为 UTC（双系统）",
    "Description": "把系统时钟按 UTC 存储，适合与 Linux 双系统共用硬件时钟，避免来回切换导致时间错乱。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Value": "1",
        "Type": "QWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/utc"
  },
  "WPFTweaksRemoveOneDrive": {
    "Content": "卸载 OneDrive",
    "Description": "先保护 OneDrive 用户文件不被误删，再调用其卸载程序移除 OneDrive，最后恢复权限。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Deny permission to remove OneDrive folder\r\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\r\n\r\n      Write-Host \"Uninstalling OneDrive...\"\r\n      Start-Process -FilePath (Join-Path $Env:SystemRoot \"System32\\OneDriveSetup.exe\") -ArgumentList '/uninstall' -Wait\r\n\r\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n      Write-Host \"Removing leftover OneDrive Files...\"\r\n\r\n      Stop-Process -Name FileCoAuth,Explorer\r\n\r\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\r\n      Remove-Item \"$Env:ProgramData\\Microsoft OneDrive\" -Recurse -Force\r\n\r\n      # Grant back permission to access OneDrive folder\r\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\r\n\r\n      if (-not (Get-ChildItem -Path $Env:OneDrive)) {\r\n          Remove-Item -Path $Env:OneDrive -Recurse\r\n          [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')\r\n      }\r\n\r\n      # Disable OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enabled OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Automatic\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removeonedrive"
  },
  "WPFTweaksRemoveHomeAndGallery": {
    "Content": "移除资源管理器的主页和图库",
    "Description": "从资源管理器移除“主页”和“图库”，并将“此电脑”设为默认页面。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "LaunchTo",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/removehomeandgallery"
  },
  "WPFTweaksDisplay": {
    "Content": "显示效果优先性能",
    "Description": "关闭部分视觉特效（动画、透明等）以提升响应速度，适合老机器或性能优先。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "DragFullWindows",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String",
        "OriginalValue": "400"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewAlphaSelect",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewShadow",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAnimations",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\DWM",
        "Name": "EnableAeroPeek",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarMn",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/display"
  },
  "WPFTweaksReservedStorage": {
    "Content": "禁用保留存储",
    "Description": "禁用 Windows 为更新和临时文件预留的约 7-10 GB 空间。仅建议小容量磁盘使用；重大功能更新前应重新启用。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "InvokeScript": [
      "DISM /Online /Set-ReservedStorageState /State:Disabled"
    ],
    "UndoScript": [
      "DISM /Online /Set-ReservedStorageState /State:Enabled"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/reservedstorage"
  },
  "WPFTweaksRestorePoint": {
    "Content": "创建系统还原点",
    "Description": "在执行优化前创建系统还原点，便于出问题时回滚（推荐先勾）。",
    "category": "基础优化",
    "panel": "1",
    "Checked": "False",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
        "Name": "SystemRestorePointCreationFrequency",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1440"
      }
    ],
    "InvokeScript": [
      "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/restorepoint"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "右键任务栏启用“结束任务”",
    "Description": "在任务栏程序右键菜单里增加“结束任务”选项，方便一键强退卡死程序。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
        "Name": "TaskbarEndTask",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/endtaskontaskbar"
  },
  "WPFTweaksStorage": {
    "Content": "关闭存储感知",
    "Description": "关闭“存储感知”（自动清理临时文件/回收站等），避免系统自动删文件。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
        "Name": "01",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/storage"
  },
  "WPFTweaksWindowsAI": {
    "Content": "禁用并移除 Windows AI",
    "Description": "禁用并移除 Windows 的 AI 功能与相关软件包。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "hide:aicomponents",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
        "Name": "DisableAIFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n\r\n      Get-AppxPackage -AllUsers \"*Copilot*\" | Remove-AppxPackage -AllUsers\r\n      winget uninstall -e --name \"Copilot\" --silent --force --accept-source-agreements 2>$null\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n\r\n      if ($Appx) {\r\n          Remove-AppxPackage $Appx\r\n      }\r\n\r\n      Set-Service -Name WSAIFabricSvc -StartupType Disabled\r\n      Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart\r\n\r\n      Write-Host \"Windows AI Disabled\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/windowsai"
  },
  "WPFTweaksWPBT": {
    "Content": "禁用 WPBT（平台二进制表）",
    "Description": "阻止系统执行 OEM 写入的 WPBT 内容，降低厂商预装/持久化程序带来的风险（高级选项）。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/wpbt"
  },
  "WPFTweaksPreventDeviceMetadataFromNetwork": {
    "Content": "阻止设备配套应用自动安装",
    "Description": "阻止接入设备时自动安装额外软件，例如连接显示器后推送的应用。可能影响部分设备功能。",
    "category": "基础优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Device Metadata",
        "Name": "PreventDeviceMetadataFromNetwork",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/preventdevicemetadatafromnetwork"
  },
  "WPFTweaksRazerBlock": {
    "Content": "阻止 Razer 软件安装",
    "Description": "阻止 Razer 相关软件/驱动的自动安装（硬件通常仍可用）。注意：也可能影响部分第三方驱动安装流程。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "\r\n      $RazerPath = \"$Env:SystemRoot\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"Everyone:(W)\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      icacls \"$Env:SystemRoot\\Installer\\Razer\" /remove:d Everyone\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/razerblock"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "禁用通知中心/日历（全部通知）",
    "Description": "禁用通知中心与日历弹窗（会关闭大部分系统通知）。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablenotifications"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "屏蔽 Adobe 联网（激活/遥测）",
    "Description": "通过 hosts 阻断部分 Adobe 激活/遥测域名，减少弹窗与联网请求（可能影响正版激活/更新，慎用）。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $hostsUrl = Invoke-RestMethod -Uri https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\r\n      Add-Content -Path \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" -Value $hostsUrl\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Added Adobe url block list from host file'\r\n      "
    ],
    "UndoScript": [
      "\r\n      Set-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" (\r\n          (Get-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\") -join \"`n\" -replace '(?s)#New Ver.*', ''\r\n      )\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Removed Adobe url block list from host file'\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/blockadobenet"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "恢复经典右键菜单",
    "Description": "恢复资源管理器右键菜单的经典布局，替换 Windows 11 的精简版菜单。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "InvokeScript": [
      "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name InprocServer32 -Value \"\" -Force\r\n      Stop-Process -Name explorer\r\n      "
    ],
    "UndoScript": [
      "Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/rightclickmenu"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "运行磁盘清理",
    "Description": "运行系统磁盘清理并清理旧组件/更新缓存，释放空间（可能需要较长时间）。",
    "category": "基础优化",
    "panel": "1",
    "InvokeScript": [
      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/diskcleanup"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "删除临时文件",
    "Description": "删除用户临时目录与系统临时目录中的文件，用于快速释放空间（可能删掉某些软件的临时缓存）。",
    "category": "基础优化",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/deletetempfiles"
  },
  "WPFTweaksIPv46": {
    "Content": "优先使用 IPv4（降低 IPv6 优先级）",
    "Description": "不完全禁用 IPv6，而是让系统优先走 IPv4；在 IPv6 配置不完整的网络里可能更稳定。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/ipv46"
  },
  "WPFTweaksTeredo": {
    "Content": "禁用 Teredo",
    "Description": "关闭 Teredo（IPv6 隧道）。可能改善延迟/安全，但可能影响部分 Xbox/联机 NAT 场景。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/teredo"
  },
  "WPFTweaksDisableIPv6": {
    "Content": "禁用 IPv6",
    "Description": "禁用 IPv6 协议栈。可能影响部分网络/内网环境；不确定就别选。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disableipv6"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "禁止商店应用后台运行",
    "Description": "禁止商店应用在后台运行，减少后台耗电/占用（可能影响通知/后台同步）。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablebgapps"
  },
  "WPFTweaksDisableFSO": {
    "Content": "禁用全屏优化",
    "Description": "禁用全屏优化（有时可减少某些游戏的输入延迟/兼容问题，但也可能影响色彩管理等）。",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_DXGIHonorFSEWindowsCompatible",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/disablefso"
  },
  "WPFTweaksDisableExplorerAutoDiscovery": {
    "Content": "禁用资源管理器自动识别文件夹类型",
    "Description": "关闭资源管理器对文件夹“自动套模板”（图片/音乐/视频等）判断，减少卡顿或模板乱跳。",
    "category": "基础优化",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/essential-tweaks/disableexplorerautodiscovery"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "详细蓝屏信息",
    "Description": "蓝屏时显示更详细的信息（对排障更友好）。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/detailedbsod"
  },
  "WPFToggleBatteryPercentage": {
    "Content": "系统托盘显示电池百分比",
    "Description": "在系统托盘的电池图标旁显示数字电量百分比。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "IsBatteryPercentageEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/batterypercentage"
  },
  "WPFToggleDarkMode": {
    "Content": "Windows 深色模式",
    "Description": "切换系统与应用深色/浅色主题。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/darkmode"
  },
  "WPFToggleShowExt": {
    "Content": "显示文件扩展名",
    "Description": "在资源管理器中显示文件扩展名（推荐，防止伪装文件）。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/showext"
  },
  "WPFToggleHiddenFiles": {
    "Content": "显示隐藏文件",
    "Description": "在资源管理器中显示隐藏文件。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hiddenfiles"
  },
  "WPFToggleVerboseLogon": {
    "Content": "登录时显示详细状态信息",
    "Description": "登录/关机时显示更详细的系统状态消息，便于排障。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/verboselogon"
  },
  "WPFToggleNewOutlook": {
    "Content": "新版 Outlook",
    "Description": "控制 Office/Outlook 是否使用“新版 Outlook”与相关切换入口（偏向保持旧版体验）。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "UseNewOutlook",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "HideNewOutlookToggle",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "DoNewOutlookAutoMigration",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "NewOutlookMigrationUserSetting",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/newoutlook"
  },
  "WPFToggleScrollbars": {
    "Content": "始终显示滚动条",
    "Description": "开启后滚动条会始终可见；关闭后 Windows 会在不使用时自动隐藏滚动条。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility",
        "Name": "DynamicScrollbars",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/scrollbars"
  },
  "WPFToggleMultiplaneOverlay": {
    "Content": "禁用 MPO（多平面叠加）",
    "Description": "禁用 MPO（多平面叠加）。某些显卡/驱动下可缓解闪屏/黑屏/画面撕裂；但可能略增耗电。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
        "Name": "OverlayTestMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "5",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
        "Name": "DisableOverlays",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/multiplaneoverlay"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "鼠标加速",
    "Description": "开关鼠标加速（关闭后鼠标更线性，适合游戏）。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/mouseacceleration"
  },
  "WPFToggleNumLock": {
    "Content": "开机自动开启 NumLock",
    "Description": "控制开机后 NumLock 是否默认开启。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/numlock"
  },
  "WPFToggleWindowSnapping": {
    "Content": "窗口贴靠",
    "Description": "控制拖动窗口时的窗口贴靠功能。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "WindowArrangementActive",
        "Value": "1",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/windowsnapping"
  },
  "WPFToggleStandbyFix": {
    "Content": "现代待机修复",
    "Description": "在 S0 睡眠期间禁用网络连接，减少现代笔记本待机发热或偷跑电。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
        "Name": "ACSettingIndex",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/standbyfix"
  },
  "WPFToggleS3Sleep": {
    "Content": "S3 睡眠（传统睡眠）",
    "Description": "切换到传统 S3 睡眠（若硬件/BIOS 支持）。有助于解决某些“睡眠唤醒异常”。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
        "Name": "PlatformAoAcOverride",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/s3sleep"
  },
  "WPFToggleHideSettingsHome": {
    "Content": "移除“设置”首页",
    "Description": "在 Windows 11 中移除“设置”应用的首页（Home）入口/内容。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "show:home",
        "Type": "String",
        "OriginalValue": "hide:home",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/hidesettingshome"
  },
  "WPFToggleBingSearch": {
    "Content": "开始菜单搜索 Bing 网页结果",
    "Description": "控制开始菜单搜索是否包含 Bing 网页结果（关掉更隐私、也更干净）。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/bingsearch"
  },
  "WPFToggleLoginBlur": {
    "Content": "登录界面亚克力模糊",
    "Description": "控制 Windows 10/11 登录界面背景的亚克力模糊效果。关闭后登录背景会更清晰。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "DisableAcrylicBackgroundOnLogon",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/loginblur"
  },
  "WPFTweaksDisableLockscreen": {
    "Content": "禁用锁屏界面",
    "Description": "跳过锁屏画面，在开机或唤醒后直接进入登录界面。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
        "Name": "NoLockScreen",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/disablelockscreen"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "开始菜单显示“推荐”",
    "Description": "控制开始菜单是否显示“推荐”区域内容。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/startmenurecommendations"
  },
  "WPFToggleStickyKeys": {
    "Content": "粘滞键",
    "Description": "开关粘滞键（连续按 Shift 触发的辅助功能）。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "506",
        "Type": "DWord",
        "OriginalValue": "58",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/stickykeys"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "任务栏图标居中",
    "Description": "切换任务栏图标居中/靠左（Win11）。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbaralignment"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "任务栏搜索按钮",
    "Description": "显示/隐藏任务栏上的搜索按钮/搜索框。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskbarsearch"
  },
  "WPFToggleTaskView": {
    "Content": "任务栏任务视图按钮",
    "Description": "显示/隐藏任务栏上的“任务视图”按钮。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/taskview"
  },
  "WPFToggleGameMode": {
    "Content": "游戏模式",
    "Description": "控制 Windows 游戏模式，使系统优先向游戏分配资源。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AllowAutoGameMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AutoGameModeEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/gamemode"
  },
  "WPFToggleLongPaths": {
    "Content": "启用长路径支持",
    "Description": "允许资源管理器使用超过 260 个字符的文件路径。",
    "category": "个性化选项",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        "Name": "LongPathsEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/code-reference/tweaks/customize-preferences/longpaths"
  },
  "WPFOOSUbutton": {
    "Content": "运行 O&O ShutUp10++（隐私工具）",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "Type": "Button",
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/oosubutton"
  },
  "WPFchangedns": {
    "Content": "DNS（快速设置）",
    "category": "z__高级优化 - 谨慎",
    "panel": "1",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
    "link": "https://winutil.christitus.com/code-reference/tweaks/z--advanced-tweaks---caution/changedns"
  },
  "WPFAddUltPerf": {
    "Content": "添加并启用“卓越性能”电源计划",
    "category": "性能电源计划 - 不适用于笔记本电脑",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/addultperf"
  },
  "WPFRemoveUltPerf": {
    "Content": "移除“卓越性能”电源计划",
    "category": "性能电源计划 - 不适用于笔记本电脑",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/code-reference/tweaks/performance-plans---not-for-laptops/removeultperf"
  }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinUtility"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="SingleBorderWindow"
        Width="Auto"
        Height="Auto"
        MinWidth="800"
        MinHeight="600"
        Title="WinUtil">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10" UseAeroCaptionButtons="False"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="5"/>
        <Setter Property="Padding" Value="6,4"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <ContentPresenter Content="{TemplateBinding Content}"
                                      VerticalAlignment="Center"
                                      HorizontalAlignment="Left"/>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style x:Key="ComboBoxToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Background="{TemplateBinding Background}" BorderThickness="0">
                            <ContentPresenter/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth"   Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border Name="OuterBorder"
                                    BorderBrush="{DynamicResource BorderColor}"
                                    BorderThickness="1"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}"
                                    Background="{TemplateBinding Background}">
                                <ToggleButton Name="ToggleButton"
                                              Style="{StaticResource ComboBoxToggleButtonStyle}"
                                              Background="Transparent"
                                              BorderThickness="0"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              ClickMode="Press">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0"
                                                   Text="{TemplateBinding SelectionBoxItem}"
                                                   Foreground="{TemplateBinding Foreground}"
                                                   Background="Transparent"
                                                   HorizontalAlignment="Left" VerticalAlignment="Center"
                                                   Margin="6,3,2,3"/>
                                        <Path Grid.Column="1"
                                              Data="M 0,0 L 8,0 L 4,5 Z"
                                              Fill="{TemplateBinding Foreground}"
                                              Width="8" Height="5"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Center"
                                              Stretch="Uniform"
                                              Margin="4,0,6,0"/>
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}"/>
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="ContentTemplate">
                <Setter.Value>
                    <DataTemplate>
                        <TextBlock Text="{Binding}" Background="Transparent"
                                   Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ComboBoxItem}}"/>
                    </DataTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <Style x:Key="TabToggleButton" TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Content" Value=""/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="ButtonGlow"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonForegroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <Border Name="BackgroundBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonBackgroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                        <ContentPresenter
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"
                                            Margin="10,2,10,2"/>
                                    </Border>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink"/>
                                <Setter Property="BorderThickness" Value="2"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent"/>
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="剪切"/>
                                                    <MenuItem Command="Copy" Header="复制"/>
                                                    <MenuItem Command="Paste" Header="粘贴"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="RoundedProgressBarStyle" TargetType="ProgressBar">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Border CornerRadius="4" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1">
                            <Grid ClipToBounds="True">
                                <Border Name="PART_Track" CornerRadius="4" Background="Transparent"/>
                                <Border Name="PART_Indicator" CornerRadius="4" Background="{DynamicResource ProgressBarForegroundColor}" HorizontalAlignment="Left"/>
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Filter Chip Style — used by the Install tab category filter buttons -->
        <Style x:Key="FilterChipStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Margin" Value="2"/>
            <Setter Property="Padding" Value="12,0,12,0"/>
            <Setter Property="Width" Value="Auto"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="ChipBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{DynamicResource ButtonBorderThickness}"
                                CornerRadius="{DynamicResource ButtonCornerRadius}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="ChipBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="&#x26A0; 离线模式 - 无网络连接" Foreground="White" FontWeight="Bold"
                HorizontalAlignment="Center" FontSize="13" Background="Transparent"/>
        </Border>
        <Grid Grid.Row="1" Background="{DynamicResource MainBackgroundColor}">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/> <!-- Navigation buttons -->
                <ColumnDefinition Width="*"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Navigation Buttons Panel -->
            <StackPanel Name="NavDockPanel" Orientation="Horizontal" Grid.Column="0" VerticalAlignment="Center" Margin="5,5,10,5">
                <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
                </StackPanel>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab1BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" >
                            <Underline>I</Underline> 安装
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFTab2BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}">
                            <Underline>T</Underline> 优化
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonConfigBackgroundColor}" Foreground="{DynamicResource ButtonConfigForegroundColor}" FontWeight="Bold" Name="WPFTab3BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonConfigForegroundColor}">
                            <Underline>C</Underline> 设置
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonUpdatesBackgroundColor}" Foreground="{DynamicResource ButtonUpdatesForegroundColor}" FontWeight="Bold" Name="WPFTab4BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonUpdatesForegroundColor}">
                            <Underline>U</Underline> 更新
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Style="{StaticResource TabToggleButton}" Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="Auto" MinWidth="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonWin11ISOBackgroundColor}" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}" FontWeight="Bold" Name="WPFTab5BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}">
                            <Underline>W</Underline> Win11 制作
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,10,0" MinWidth="120" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Stretch">
                    <Grid>
                        <TextBox
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Stretch"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,30,0"
                            ToolTip="按 Ctrl+F 输入应用名称以筛选下方列表；按 Esc 清除筛选">
                        </TextBox>
                        <TextBlock
                            Name="SearchBarIcon"
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Right"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    Margin="0,0,20,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="切换 WinUtil 界面主题"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="自动" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="跟随系统主题"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="深色" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="使用深色主题"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="浅色" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="使用浅色主题"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="调整字体缩放（便于阅读/无障碍）"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="字体缩放"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="小"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"/>
                                <TextBlock Text="大"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="重置"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="应用"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="导入" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="从导出的文件导入配置。"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="导出" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="导出所选项目，并将执行命令复制到剪贴板。"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="关于" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="文档" Name="DocumentationMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="赞助" Name="SponsorMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button
                        Content="&#xE921;"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        ToolTip="最小化"
                        AutomationProperties.Name="Minimize"
                        Name="WPFMinimizeButton" />
                    <Button
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0,0,0,0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        Name="WPFMaximizeButton">
                        <Button.Style>
                            <Style TargetType="Button" BasedOn="{StaticResource HoverButtonStyle}">
                                <Setter Property="Content" Value="&#xE922;"/>
                                <Setter Property="ToolTip" Value="Maximize"/>
                                <Setter Property="AutomationProperties.Name" Value="Maximize"/>
                                <Style.Triggers>
                                    <DataTrigger Binding="{Binding WindowState, RelativeSource={RelativeSource AncestorType={x:Type Window}}}" Value="Maximized">
                                        <Setter Property="Content" Value="&#xE923;"/>
                                        <Setter Property="ToolTip" Value="Restore"/>
                                        <Setter Property="AutomationProperties.Name" Value="Restore"/>
                                    </DataTrigger>
                                </Style.Triggers>
                            </Style>
                        </Button.Style>
                    </Button>

                    <Button
                        Content="&#xE8BB;"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderThickness="0"
                        BorderBrush="Transparent"
                        Background="{DynamicResource MainBackgroundColor}"
                        Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                        HorizontalAlignment="Right" VerticalAlignment="Center"
                        Margin="0"
                        FontFamily="Segoe MDL2 Assets"
                        Foreground="{DynamicResource MainForegroundColor}"
                        FontSize="{DynamicResource CloseIconFontSize}"
                        ToolTip="关闭"
                        AutomationProperties.Name="Close"
                        Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="0" Padding="-1">
            <TabItem Header="安装" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Quick Category Search Chips -->
                    <WrapPanel Grid.Row="0" Orientation="Horizontal" Margin="5,5,5,5" Name="WPFSearchChips">
                        <TextBlock Text="分类筛选"
                                   FontSize="{DynamicResource HeaderFontSize}"
                                   FontFamily="{DynamicResource HeaderFontFamily}"
                                   Foreground="{DynamicResource LabelboxForegroundColor}"
                                   Background="Transparent"
                                   VerticalAlignment="Center"
                                   Margin="15,0,8,0"/>
                        <Button Name="WPFSearchChipAll"             Content="全部"               Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipBrowsers"        Content="浏览器"          Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipCommunications"  Content="通信"    Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipDevelopment"     Content="开发"       Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipDocument"        Content="文档"          Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipGames"           Content="游戏"             Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipMicrosoftTools"  Content="微软工具"   Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipMultimediaTools" Content="多媒体工具"  Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipProTools"        Content="专业工具"         Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipSelfhostedTools" Content="自托管工具"  Style="{StaticResource FilterChipStyle}"/>
                        <Button Name="WPFSearchChipUtilities"       Content="实用工具"         Style="{StaticResource FilterChipStyle}"/>
                    </WrapPanel>

                    <Grid Grid.Row="1" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="优化" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="推荐预设：" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" 标准 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFminimal" Content=" 最小化 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFAdvanced" Content=" 高级 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearTweaksSelection" Content=" 清除 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledTweaks" Content=" 获取已安装优化 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFAppxRemoval" Content=" AppX 移除 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </WrapPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        Note: Hover over items to get a better description. Please be careful as many of these tweaks will heavily modify your system.
                                        <LineBreak/>Recommended selections are for normal users and if you are unsure do NOT check anything else!
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="执行优化" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFUndoall" Content="撤销所选优化" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="配置" Visibility="Collapsed" Name="WPFTab3">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="更新" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent" MaxWidth="1250" HorizontalAlignment="Center">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <StackPanel Grid.Row="0" Margin="10,10,10,14">
                            <TextBlock Text="Windows 更新策略"
                                       FontSize="24"
                                       FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="选择 Windows 接收更新的方式。每种策略都会替换由 WinUtil 管理的 Windows 更新设置。"
                                       Margin="0,6,0,0"
                                       FontSize="13"
                                       TextWrapping="Wrap"
                                       Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>

                        <UniformGrid Grid.Row="1" Columns="3">
                            <Border Style="{StaticResource BorderStyle}"
                                    BorderBrush="{DynamicResource ProgressBarForegroundColor}"
                                    BorderThickness="2"
                                    Padding="16"
                                    MinHeight="300">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0" Margin="0,0,0,14">
                                        <TextBlock Text="推荐"
                                                   FontSize="20"
                                                   FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="兼顾安全性与稳定性"
                                                   Margin="0,4,0,0"
                                                   FontSize="13"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <StackPanel Grid.Row="1">
                                        <TextBlock Text="- 功能更新延后 365 天" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- 质量更新延后 4 天" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- 质量更新不包含驱动程序" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- 用户登录期间阻止自动重启" TextWrapping="Wrap" Margin="0,0,0,12" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="适用于 Windows 专业版、企业版和教育版。"
                                                   FontSize="11"
                                                   FontStyle="Italic"
                                                   TextWrapping="Wrap"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            Grid.Row="2"
                                            Content="应用推荐设置"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Margin="0,16,0,0"
                                            Padding="10"/>
                                </Grid>
                            </Border>

                            <Border Style="{StaticResource BorderStyle}" Padding="16" MinHeight="300">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0" Margin="0,0,0,14">
                                        <TextBlock Text="Windows 默认"
                                                   FontSize="20"
                                                   FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="将更新控制权交还 Windows"
                                                   Margin="0,4,0,0"
                                                   FontSize="13"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <StackPanel Grid.Row="1">
                                        <TextBlock Text="- 移除 WinUtil 应用的 Windows 更新策略" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- 恢复更新服务的启动设置" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- 重新启用更新计划任务" TextWrapping="Wrap" Margin="0,0,0,12" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="用此选项撤销“推荐”或“禁用更新”策略。"
                                                   FontSize="11"
                                                   FontStyle="Italic"
                                                   TextWrapping="Wrap"
                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                    </StackPanel>
                                    <Button Name="WPFUpdatesdefault"
                                            Grid.Row="2"
                                            Content="恢复默认设置"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Margin="0,16,0,0"
                                            Padding="10"/>
                                </Grid>
                            </Border>

                            <Border Style="{StaticResource BorderStyle}" Padding="16" MinHeight="300">
                                <Grid>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="*"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <StackPanel Grid.Row="0" Margin="0,0,0,14">
                                        <TextBlock Text="禁用更新"
                                                   FontSize="20"
                                                   FontWeight="Bold"
                                                   Foreground="Red"/>
                                        <TextBlock Text="仅供高级用户使用"
                                                   Margin="0,4,0,0"
                                                   FontSize="13"
                                                   FontWeight="SemiBold"
                                                   Foreground="Red"/>
                                    </StackPanel>
                                    <StackPanel Grid.Row="1">
                                        <TextBlock Text="- 禁用自动更新策略" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- 停止更新服务和计划任务" TextWrapping="Wrap" Margin="0,0,0,7" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="- 清理已下载的更新文件" TextWrapping="Wrap" Margin="0,0,0,12" Foreground="{DynamicResource MainForegroundColor}"/>
                                        <TextBlock Text="启用此策略期间不会安装安全更新。"
                                                   FontSize="11"
                                                   FontStyle="Italic"
                                                   TextWrapping="Wrap"
                                                   Foreground="Red"/>
                                    </StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            Grid.Row="2"
                                            Content="禁用更新"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Foreground="Red"
                                            Margin="0,16,0,0"
                                            Padding="10"/>
                                </Grid>
                            </Border>
                        </UniformGrid>

                        <Border Grid.Row="2" Style="{StaticResource BorderStyle}" Margin="8,14,8,8" Padding="12">
                            <TextBlock Text="更改会作用于整个系统。切换策略后请重启 Windows；可用“恢复默认设置”撤销 WinUtil 更新策略。"
                                       TextWrapping="Wrap"
                                       HorizontalAlignment="Center"
                                       Foreground="{DynamicResource MainForegroundColor}"/>
                        </Border>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Win11ISO（镜像制作）" Visibility="Collapsed" Name="WPFTab5">
                <Grid Name="Win11ISOPanel" Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>  <!-- Steps 1-4 -->
                        <RowDefinition Height="*"/>     <!-- Log / Status -->
                    </Grid.RowDefinitions>

                    <!-- Steps 1-4 -->
                    <StackPanel Grid.Row="0">

                            <!-- ─── STEP 1 : Select Windows 11 ISO ─────────────── -->
                            <Grid Name="WPFWin11ISOSelectSection" Margin="5" HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Left: File Selector -->
                                <StackPanel Grid.Column="0" Margin="5,5,15,5">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        步骤 1：选择 Windows 11 ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,6">
                                        浏览到你本地保存的 Windows 11 ISO 文件。
                                        仅支持微软官方原版 ISO。
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" FontStyle="Italic">
                                        <Run FontWeight="Bold">注意：</Run> 这个流程只适用于全新/重装场景。
                                    </TextBlock>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox Grid.Column="0"
                                                 Name="WPFWin11ISOPath"
                                                 IsReadOnly="True"
                                                 VerticalAlignment="Center"
                                                 Padding="6,4"
                                                 Margin="0,0,6,0"
                                                 Text="尚未选择 ISO..."
                                                 Foreground="{DynamicResource MainForegroundColor}"
                                                 Background="{DynamicResource MainBackgroundColor}"/>
                                        <Button Grid.Column="1"
                                                Name="WPFWin11ISOBrowseButton"
                                                Content="浏览"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </Grid>
                                    <TextBlock Name="WPFWin11ISOFileInfo"
                                               FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               Margin="0,8,0,0"
                                               TextWrapping="Wrap"
                                               Visibility="Collapsed"/>
                                </StackPanel>

                                <!-- Right: Download guidance -->
                                <Border Grid.Column="1"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Margin="5" Padding="15">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="OrangeRed" Margin="0,0,0,10">
                                            ！！警告！！必须使用微软官方 ISO
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            请直接从 Microsoft.com 下载 Windows 11 ISO。
                                            不支持第三方、预修改或非官方镜像，
                                            否则可能产生异常结果。
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,6">
                                            在微软下载页面中请选择：
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="12,0,0,12">
                                            - 版本：Windows 11
                                            <LineBreak/>- 语言：你需要的语言
                                            <LineBreak/>- 架构：64 位（x64）
                                        </TextBlock>
                                        <Button Name="WPFWin11ISODownloadLink"
                                                Content="打开微软下载页面"
                                                HorizontalAlignment="Left"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- ─── STEP 2 : Mount & Verify ISO ──────────────────── -->
                            <Grid Name="WPFWin11ISOMountSection"
                                  Margin="5"
                                  Visibility="Collapsed"
                                  HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,20,0" VerticalAlignment="Top">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        步骤 2：挂载并验证 ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" MaxWidth="320">
                                        挂载 ISO，并确认其中包含有效的 Windows 11
                                        install.wim，然后再开始修改。
                                    </TextBlock>
                                    <Button Name="WPFWin11ISOMountButton"
                                            Content="挂载并验证 ISO"
                                            HorizontalAlignment="Left"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <CheckBox Name="WPFWin11ISOInjectDrivers"
                                              Content="注入当前系统驱动"
                                              FontSize="{DynamicResource FontSize}"
                                              Foreground="{DynamicResource MainForegroundColor}"
                                              IsChecked="False"
                                              Margin="0,8,0,0"
                                              ToolTip="为安装程序准备启动存储驱动，并通过一次 DISM 操作把导出的全部驱动加入所选 install.wim 版本。"/>
                                </StackPanel>

                                <!-- Verification results panel -->
                                <Border Grid.Column="1"
                                        Name="WPFWin11ISOVerifyResultPanel"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Padding="12" Margin="0,0,0,0"
                                        Visibility="Collapsed">
                                    <StackPanel>
                                        <TextBlock Name="WPFWin11ISOMountDriveLetter"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock Name="WPFWin11ISOArchLabel"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,6,0,4">
                                            选择版本：
                                        </TextBlock>
                                        <ComboBox Name="WPFWin11ISOEditionComboBox"
                                                  FontSize="{DynamicResource FontSize}"
                                                  Foreground="{DynamicResource MainForegroundColor}"
                                                  Background="{DynamicResource MainBackgroundColor}"
                                                  HorizontalAlignment="Left"
                                                  Margin="0,0,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- ─── STEP 3 : Modify install.wim ───────────────────── -->
                            <StackPanel Name="WPFWin11ISOModifySection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                    步骤 3：修改 install.wim
                                </TextBlock>
                                <TextBlock FontSize="{DynamicResource FontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           TextWrapping="Wrap" Margin="0,0,0,12">
                                    ISO 内容会先解压到临时工作目录，
                                    然后修改 install.wim（移除组件、应用优化），
                                    最后重新打包。整个过程可能需要数分钟，
                                    具体取决于你的硬件性能。
                                </TextBlock>
                                <Button Name="WPFWin11ISOModifyButton"
                                        Content="开始修改并生成镜像"
                                        HorizontalAlignment="Left"
                                        Width="Auto" Padding="12,0"
                                        Height="{DynamicResource ButtonHeight}"/>
                            </StackPanel>

                            <!-- ─── STEP 4 : Output Options ───────────────────────── -->
                            <StackPanel Name="WPFWin11ISOOutputSection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <!-- Header row: title + Clean & Reset button -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               VerticalAlignment="Center">
                                        步骤 4：输出方式 - 你想如何处理修改后的镜像？
                                    </TextBlock>
                                    <Button Grid.Column="1"
                                            Name="WPFWin11ISOCleanResetButton"
                                            Content="清理并重置"
                                            Foreground="OrangeRed"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"
                                            ToolTip="删除临时工作目录，并把界面重置回步骤 1"
                                            Margin="12,0,0,0"/>
                                </Grid>

                                <!-- ── Choice prompt buttons ── -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="16"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Button Grid.Column="0"
                                            Name="WPFWin11ISOChooseISOButton"
                                            Content="保存为 ISO 文件"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <Button Grid.Column="2"
                                            Name="WPFWin11ISOChooseUSBButton"
                                            Content="直接写入 USB 盘（会清空磁盘）"
                                            Foreground="OrangeRed"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                </Grid>

                                <!-- ── USB write sub-panel (revealed on USB choice) ── -->
                                <Border Name="WPFWin11ISOOptionUSB"
                                        Style="{StaticResource BorderStyle}"
                                        Visibility="Collapsed"
                                        Margin="0,8,0,0">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            <Run FontWeight="Bold" Foreground="OrangeRed">！！所选 USB 盘上的所有数据都会被永久清除！！</Run>
                                            <LineBreak/>
                                            在下方选择可移动 USB 盘，然后点击“擦除并写入”。
                                        </TextBlock>
                                        <!-- USB drive selector row -->
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <ComboBox Grid.Column="0"
                                                      Name="WPFWin11ISOUSBDriveComboBox"
                                                      Foreground="{DynamicResource MainForegroundColor}"
                                                      Background="{DynamicResource MainBackgroundColor}"
                                                      VerticalAlignment="Center"
                                                      Margin="0,0,6,0"/>
                                            <Button Grid.Column="1"
                                                    Name="WPFWin11ISORefreshUSBButton"
                                                    Content="刷新"
                                                    Width="Auto" Padding="8,0"
                                                    Height="{DynamicResource ButtonHeight}"/>
                                        </Grid>
                                        <Button Name="WPFWin11ISOWriteUSBButton"
                                                Content="擦除并写入 USB"
                                                Foreground="OrangeRed"
                                                HorizontalAlignment="Stretch"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"
                                                Margin="0,0,0,10"/>
                                    </StackPanel>
                                </Border>
                            </StackPanel>

                    </StackPanel>

                    <!-- Status Log (fills remaining height) -->
                    <Grid Grid.Row="1" Margin="5">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0"
                                   FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                   Foreground="{DynamicResource MainForegroundColor}"
                                   Margin="0,0,0,4">
                            状态日志
                        </TextBlock>
                        <TextBox Grid.Row="1"
                                 Name="WPFWin11ISOStatusLog"
                                 IsReadOnly="True"
                                 TextWrapping="Wrap"
                                 VerticalScrollBarVisibility="Visible"
                                 VerticalAlignment="Stretch"
                                 Padding="6"
                                 Background="{DynamicResource MainBackgroundColor}"
                                 Foreground="{DynamicResource MainForegroundColor}"
                                 BorderBrush="{DynamicResource BorderColor}"
                                 BorderThickness="1"
                                 Text="已就绪。请选择一个 Windows 11 ISO 以开始。"/>
                    </Grid>

                </Grid>
            </TabItem>
            <TabItem Header="AppX" Visibility="Collapsed" Name="WPFTab6">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Margin="5">
                                <Label Content="选择项目：" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFDefaultAppxSelection" Content=" 默认 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledAppx" Content=" 获取已安装项 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFSelectAllAppx" Content=" 全选 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearAppxSelection" Content=" 清空选择 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="appxpanel" Grid.Row="1">
                            </Grid>

                            <Border Grid.Row="2" Style="{StaticResource BorderStyle}" Margin="5,15,5,5">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}">
                                        Note: Select the Windows AppX packages you wish to install or remove.
                                        <LineBreak/>Install Selected registers a local manifest when available, then falls back to the Microsoft Store.
                                        <LineBreak/>Remove Selected removes packages for the current user and all new user profiles.
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>

                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                            <Button Name="WPFBackToTweaks" Content="返回优化" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFInstallSelectedAppx" Content="安装所选项" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFRemoveSelectedAppx" Content="移除所选项" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- Window-level progress indicator - visible regardless of active tab -->
        <Border Name="WPFTweaksProgressBar" Grid.Row="3" Background="{DynamicResource MainBackgroundColor}" Visibility="Collapsed" Padding="10,6">
            <StackPanel Orientation="Vertical">
                <TextBlock Name="WPFTweaksProgressLabel" Text="" Foreground="{DynamicResource MainForegroundColor}" FontSize="13" Background="Transparent" Margin="0,0,0,4"/>
                <ProgressBar Name="WPFTweaksProgressValue" Height="6" Minimum="0" Maximum="100" Value="0" Style="{StaticResource RoundedProgressBarStyle}"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>

'@
$WinUtilAutounattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <!--https://schneegans.de/windows/unattend-generator/?LanguageMode=Interactive&ProcessorArchitecture=amd64&BypassRequirementsCheck=true&ComputerNameMode=Random&CompactOsMode=Default&TimeZoneMode=Implicit&PartitionMode=Interactive&DiskAssertionMode=Skip&WindowsEditionMode=Interactive&InstallFromMode=Automatic&PEMode=Default&UserAccountMode=InteractiveLocal&PasswordExpirationMode=Unlimited&LockoutMode=Default&HideFiles=Hidden&ClassicContextMenu=true&LaunchToThisPC=true&ShowEndTask=true&TaskbarSearch=Hide&TaskbarIconsMode=Empty&DisableWidgets=true&LeftTaskbar=true&HideTaskViewButton=true&StartTilesMode=Default&StartPinsMode=Empty&EnableLongPaths=true&HideEdgeFre=true&DisableEdgeStartupBoost=true&DeleteWindowsOld=true&EffectsMode=Default&DeleteEdgeDesktopIcon=true&DesktopIconsMode=Default&StartFoldersMode=Default&WifiMode=Skip&ExpressSettings=DisableAll&LockKeysMode=Configure&CapsLockInitial=Off&CapsLockBehavior=Toggle&NumLockInitial=On&NumLockBehavior=Toggle&ScrollLockInitial=Off&ScrollLockBehavior=Toggle&StickyKeysMode=Disabled&ColorMode=Custom&SystemColorTheme=Dark&AppsColorTheme=Dark&AccentColor=%230078d4&WallpaperMode=Default&LockScreenMode=Default&WdacMode=Skip&AppLockerMode=Skip-->
    <settings pass="offlineServicing"></settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <UseConfigurationSet>false</UseConfigurationSet>
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="generalize"></settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\Specialize.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\DefaultUser.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>6</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>7</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>8</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ShippedWithReserves /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="auditSystem"></settings>
    <settings pass="auditUser"></settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\FirstLogon.ps1"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
        <ExtractScript>
param(
    [xml]$Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
        </ExtractScript>
        <File path="C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml">
&lt;LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"&gt;
    &lt;CustomTaskbarLayoutCollection PinListPlacement="Replace"&gt;
        &lt;defaultlayout:TaskbarLayout&gt;
            &lt;taskbar:TaskbarPinList&gt;
                &lt;taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" /&gt;
            &lt;/taskbar:TaskbarPinList&gt;
        &lt;/defaultlayout:TaskbarLayout&gt;
    &lt;/CustomTaskbarLayoutCollection&gt;
&lt;/LayoutModificationTemplate&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.vbs">
HKU = &amp;H80000003
Set reg = GetObject("winmgmts://./root/default:StdRegProv")
Set fso = CreateObject("Scripting.FileSystemObject")

If reg.EnumKey(HKU, "", sids) = 0 Then
    If Not IsNull(sids) Then
        For Each sid In sids
            key = sid + "\Software\Policies\Microsoft\Windows\Explorer"
            name = "LockedStartLayout"
            If reg.GetDWORDValue(HKU, key, name, existing) = 0 Then
                reg.SetDWORDValue HKU, key, name, 0
            End If
        Next
    End If
End If
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.xml">
&lt;Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"&gt;
    &lt;Triggers&gt;
        &lt;EventTrigger&gt;
            &lt;Enabled&gt;true&lt;/Enabled&gt;
            &lt;Subscription&gt;&amp;lt;QueryList&amp;gt;&amp;lt;Query Id="0" Path="Application"&amp;gt;&amp;lt;Select Path="Application"&amp;gt;*[System[Provider[@Name='UnattendGenerator'] and EventID=1]]&amp;lt;/Select&amp;gt;&amp;lt;/Query&amp;gt;&amp;lt;/QueryList&amp;gt;&lt;/Subscription&gt;
        &lt;/EventTrigger&gt;
    &lt;/Triggers&gt;
    &lt;Principals&gt;
        &lt;Principal id="Author"&gt;
            &lt;UserId&gt;S-1-5-18&lt;/UserId&gt;
            &lt;RunLevel&gt;LeastPrivilege&lt;/RunLevel&gt;
        &lt;/Principal&gt;
    &lt;/Principals&gt;
    &lt;Settings&gt;
        &lt;MultipleInstancesPolicy&gt;IgnoreNew&lt;/MultipleInstancesPolicy&gt;
        &lt;DisallowStartIfOnBatteries&gt;false&lt;/DisallowStartIfOnBatteries&gt;
        &lt;StopIfGoingOnBatteries&gt;false&lt;/StopIfGoingOnBatteries&gt;
        &lt;AllowHardTerminate&gt;true&lt;/AllowHardTerminate&gt;
        &lt;StartWhenAvailable&gt;false&lt;/StartWhenAvailable&gt;
        &lt;RunOnlyIfNetworkAvailable&gt;false&lt;/RunOnlyIfNetworkAvailable&gt;
        &lt;IdleSettings&gt;
            &lt;StopOnIdleEnd&gt;true&lt;/StopOnIdleEnd&gt;
            &lt;RestartOnIdle&gt;false&lt;/RestartOnIdle&gt;
        &lt;/IdleSettings&gt;
        &lt;AllowStartOnDemand&gt;true&lt;/AllowStartOnDemand&gt;
        &lt;Enabled&gt;true&lt;/Enabled&gt;
        &lt;Hidden&gt;false&lt;/Hidden&gt;
        &lt;RunOnlyIfIdle&gt;false&lt;/RunOnlyIfIdle&gt;
        &lt;WakeToRun&gt;false&lt;/WakeToRun&gt;
        &lt;ExecutionTimeLimit&gt;PT72H&lt;/ExecutionTimeLimit&gt;
        &lt;Priority&gt;7&lt;/Priority&gt;
    &lt;/Settings&gt;
    &lt;Actions Context="Author"&gt;
        &lt;Exec&gt;
            &lt;Command&gt;C:\Windows\System32\wscript.exe&lt;/Command&gt;
            &lt;Arguments&gt;C:\Windows\Setup\Scripts\UnlockStartLayout.vbs&lt;/Arguments&gt;
        &lt;/Exec&gt;
    &lt;/Actions&gt;
&lt;/Task&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\SetStartPins.ps1">
$json = '{"pinnedList":[]}';
if( [System.Environment]::OSVersion.Version.Build -lt 20000 ) {
    return;
}
$key = 'Registry::HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start';
New-Item -Path $key -ItemType 'Directory' -ErrorAction 'SilentlyContinue';
Set-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins' -Value $json -Type 'String';
        </File>
        <File path="C:\Windows\Setup\Scripts\SetColorTheme.ps1">
$lightThemeSystem = 0;
$lightThemeApps = 0;
$accentColorOnStart = 0;
$enableTransparency = 0;
$htmlAccentColor = '#0078D4';
&amp; {
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
        Force = $true;
        Type = 'DWord';
    };
    Set-ItemProperty @params -Name 'SystemUsesLightTheme' -Value $lightThemeSystem;
    Set-ItemProperty @params -Name 'AppsUseLightTheme' -Value $lightThemeApps;
    Set-ItemProperty @params -Name 'ColorPrevalence' -Value $accentColorOnStart;
    Set-ItemProperty @params -Name 'EnableTransparency' -Value $enableTransparency;
};
&amp; {
    Add-Type -AssemblyName 'System.Drawing';
    $accentColor = [System.Drawing.ColorTranslator]::FromHtml( $htmlAccentColor );

    function ConvertTo-DWord {
        param(
            [System.Drawing.Color]
            $Color
        );

        [byte[]]$bytes = @(
            $Color.R;
            $Color.G;
            $Color.B;
            $Color.A;
        );
        return [System.BitConverter]::ToUInt32( $bytes, 0);
    }

    $startColor = [System.Drawing.Color]::FromArgb( 0xD2, $accentColor );
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';
        Name = 'AccentPalette';
    };
    $palette = Get-ItemPropertyValue @params;
    $index = 20;
    $palette[ $index++ ] = $accentColor.R;
    $palette[ $index++ ] = $accentColor.G;
    $palette[ $index++ ] = $accentColor.B;
    $palette[ $index++ ] = $accentColor.A;
    Set-ItemProperty @params -Value $palette -Type 'Binary' -Force;
};
        </File>
        <File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
    {
        reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f;
    };
    {
        net.exe accounts /maxpwage:UNLIMITED;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f;
        [System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' );
    };
    {
        Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UnlockStartLayout.xml' -Raw );
    };
    {
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
    };
    {
        Remove-Item -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk' -ErrorAction 'SilentlyContinue' -Verbose;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v StartupBoostEnabled /t REG_DWORD /d 0 /f;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetStartPins.ps1';
    };
    {
        reg.exe add "HKU\.DEFAULT\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\Specialize.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
    {
        [System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 );
    };
    {
        Remove-Item -Path "${env:USERPROFILE}\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
        Remove-Item -Path "$env:HOMEDRIVE\Users\Default\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
    };
    {
        $taskbarPath = "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar";
        if( Test-Path $taskbarPath ) {
            Get-ChildItem -Path $taskbarPath -File | Remove-Item -Force;
        }
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesRemovedChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'Favorites' -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetColorTheme.ps1';
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /v Enabled /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v AllAppsViewMode /t REG_DWORD /d 2 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_AccountNotifications /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowAllPinsList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowFrequentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowRecentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackDocs /t REG_DWORD /d 0 /f;
    };
    {
        Restart-Computer -Force;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "$env:TEMP\UserOnce.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
    {
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "StartLayoutFile" /t REG_SZ /d "C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml" /f;
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "LockedStartLayout" /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f;
    };
    {
        foreach( $root in 'Registry::HKU\.DEFAULT', 'Registry::HKU\DefaultUser' ) {
          Set-ItemProperty -LiteralPath "$root\Control Panel\Keyboard" -Name 'InitialKeyboardIndicators' -Type 'String' -Value 2 -Force;
        }
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle \""Normal\"" -ExecutionPolicy \""Unrestricted\"" -NoProfile -File \""C:\Windows\Setup\Scripts\UserOnce.ps1\""" /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\DefaultUser.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
    {
        Remove-Item -LiteralPath @(
          'C:\Windows\Panther\unattend.xml';
          'C:\Windows\Panther\unattend-original.xml';
          'C:\Windows\Setup\Scripts\Wifi.xml';
          'C:\Windows.old';
        ) -Recurse -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f;
        reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;
        $services = @{ BITS = 'Manual'; wuauserv = 'Manual'; UsoSvc = 'Automatic'; WaaSMedicSvc = 'Manual' };
        foreach ($name in $services.Keys) {
            Set-Service -Name $name -StartupType $services[$name] -ErrorAction SilentlyContinue;
        }
    };
    {
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /v IsEducationEnvironment /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
    };
    {
        $recallFeature = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -like 'Recall' };
        if( $recallFeature ) {
            Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -ErrorAction SilentlyContinue;
        }
    };
    {
        $viveDir = Join-Path $env:TEMP 'ViVeTool';
        $viveZip = Join-Path $env:TEMP 'ViVeTool.zip';
        Invoke-WebRequest 'https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip' -OutFile $viveZip;
        Expand-Archive -Path $viveZip -DestinationPath $viveDir -Force;
        Remove-Item -Path $viveZip -Force;
        Start-Process -FilePath (Join-Path $viveDir 'ViVeTool.exe') -ArgumentList '/disable /id:47205210' -Wait -NoNewWindow;
        Remove-Item -Path $viveDir -Recurse -Force;
    };
    {
        Start-Process C:\Windows\System32\OneDriveSetup.exe -ArgumentList /uninstall
    };
    {
        if( (Get-BitLockerVolume -MountPoint $Env:SystemDrive).ProtectionStatus -eq 'On' ) {
            Disable-BitLocker -MountPoint $Env:SystemDrive;
        }
    };
    {
        if( (bcdedit | Select-String 'path').Count -eq 2 ) {
            bcdedit /set `{bootmgr`} timeout 0;
        }
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\FirstLogon.log";
        </File>
    </Extensions>
</unattend>

'@
Write-Host @"
    CCCCCCCCCCCCCTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT
 CCC::::::::::::CT:::::::::::::::::::::TT:::::::::::::::::::::T
CC:::::::::::::::CT:::::::::::::::::::::TT:::::::::::::::::::::T
C:::::CCCCCCCC::::CT:::::TT:::::::TT:::::TT:::::TT:::::::TT:::::T
C:::::C       CCCCCCTTTTTT  T:::::T  TTTTTTTTTTTT  T:::::T  TTTTTT
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C       CCCCCC        T:::::T                T:::::T
C:::::CCCCCCCC::::C      TT:::::::TT            TT:::::::TT
CC:::::::::::::::C       T:::::::::T            T:::::::::T
CCC::::::::::::C         T:::::::::T            T:::::::::T
  CCCCCCCCCCCCC          TTTTTTTTTTT            TTTTTTTTTTT

====Chris Titus Tech=====
=====Windows Toolbox=====
"@

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object {
    $sync.configs.appxHashtable[$_.Name] = $_.Value
}
$sync.preferences.theme = "Auto"
$sync.preferences.packagemanager = "Winget"

if ($Preset) {
    Initialize-WinUtilRunspacePool | Out-Null

    # Selects the tweaks from $Preset varible
    Update-WinUtilSelections -flatJson $sync.configs.preset.$Preset

    # Run tweaks that were selected by Update-WinUtilSelections
    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

if ($Config) {
    Initialize-WinUtilRunspacePool | Out-Null

    Invoke-WPFImpex -type "import" -Config $Config

    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "XAML 代码存在问题，请检查这个控件附近的语法。" -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "请确保 `$inputXML 里的 &lt;button 不要带 Click=ButtonClick 属性，PowerShell 不能直接处理它。`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "无法加载 Windows.Markup.XamlReader，请检查语法，并确认 .NET 已安装。" -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "使用 Windows.Markup.XamlReader 的 Load 方法解析 XAML 失败。" -ForegroundColor Red
    Write-Host "Quitting WinUtil..." -ForegroundColor Red
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        $null = $hwnd, $wParam, $lParam
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Build only the default tab before first paint; other tabs initialize on first activation.
$sync.InitializedTabs = @{}
Initialize-WinUtilTabContent -TabName "Install"

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Choco"
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Winget"
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

    }
}

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "W" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        $keyEventArgs = $_
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
    $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
        $keyEventArgs = $_
        switch ($_.Key) {
            { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
            { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
$sync["Form"].Add_PreviewMouseWheel({
    if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
})

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            }
            else{
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            }
    }
})

$sync["Form"].Add_Deactivated({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height
        $sync.Form.MinWidth = [Math]::Min([double]$sync.Form.MinWidth, [double]$screenWidth)

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        }
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "安装应用需要网络连接。"

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "检测到离线模式，已禁用安装标签页。" -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab2BT"  # Switch to Tweaks tab instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab1BT"  # Default to install tab
    }

    $sync["Form"].Focus()
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true }) | Out-Null
})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Category $sync.SearchBar.Tag
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "AppX" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Tag -ne $sync.SearchBar.Text) {
        $sync.SearchBar.Tag = $null
    }

    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
        $sync.SearchBarIcon.Visibility = "Collapsed"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
        $sync.SearchBarIcon.Visibility = "Visible"
    }

    # Category chip handlers apply their filter immediately.
    if ($sync.SearchBar.Tag -eq $sync.SearchBar.Text) {
        return
    }

    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

# Quick Category Search Chips
$sync["WPFSearchChipAll"].Add_Click({ Set-WinUtilAppCategoryFilter })
$sync["WPFSearchChipBrowsers"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Browsers" })
$sync["WPFSearchChipCommunications"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Communications" })
$sync["WPFSearchChipDevelopment"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Development" })
$sync["WPFSearchChipDocument"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Document" })
$sync["WPFSearchChipGames"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Games" })
$sync["WPFSearchChipMicrosoftTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Microsoft Tools" })
$sync["WPFSearchChipMultimediaTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Multimedia Tools" })
$sync["WPFSearchChipProTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Pro Tools" })
$sync["WPFSearchChipSelfhostedTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Selfhosted Tools" })
$sync["WPFSearchChipUtilities"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Utilities" })

$sync["Form"].Add_Loaded({
    param($e)
    $null = $e
    $sync.Form.MinWidth = "1150"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
$NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null
Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
作者     : <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
界面     : <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
运行空间 : <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>
GitHub   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
版本     : <a href="https://github.com/ChrisTitusTech/winutil/releases/tag/$($sync.version)">$($sync.version)</a>
"@
    Show-CustomDialog -Title "关于" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process "https://winutil.christitus.com/"
})
$sync["SponsorMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
<a href="https://github.com/sponsors/ChrisTitusTech">Current sponsors for ChrisTitusTech:</a>
"@
    $authorInfo += "`n"
    try {
        $sponsors = Invoke-WinUtilSponsors
        foreach ($sponsor in $sponsors) {
            $authorInfo += "<a href=`"https://github.com/sponsors/ChrisTitusTech`">$sponsor</a>`n"
        }
    } catch {
        $authorInfo += "An error occurred while fetching or processing the sponsors: $_`n"
    }
    Show-CustomDialog -Title "赞助" -Message $authorInfo -EnableScroll $true
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

# ── Win11ISO Tab button handlers ──────────────────────────────────────────────

$sync["WPFWin11ISOBrowseButton"].Add_Click({
    Invoke-WinUtilISOBrowse
})

$sync["WPFWin11ISODownloadLink"].Add_Click({
    Start-Process "https://www.microsoft.com/software-download/windows11"
})

$sync["WPFWin11ISOMountButton"].Add_Click({
    Invoke-WinUtilISOMountAndVerify
})

$sync["WPFWin11ISOModifyButton"].Add_Click({
    Invoke-WinUtilISOModify
})

$sync["WPFWin11ISOChooseISOButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
    Invoke-WinUtilISOExport
})

$sync["WPFWin11ISOChooseUSBButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISORefreshUSBButton"].Add_Click({
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISOWriteUSBButton"].Add_Click({
    Invoke-WinUtilISOWriteUSB
})

$sync["WPFWin11ISOCleanResetButton"].Add_Click({
    Invoke-WinUtilISOCleanAndReset
})

function Remove-WinUtilTempScript {
    <#
    .SYNOPSIS
        Removes the temporary script downloaded by windev.ps1.

    .DESCRIPTION
        Deletes the current script only when it is a winutil-*.ps1 file in
        the system temporary directory. This preserves normal file-backed
        and in-memory WinUtil launches.
    #>

    $scriptPath = $PSCommandPath
    $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')

    if (
        $scriptPath -and
        [IO.Path]::GetDirectoryName($scriptPath) -eq $tempPath -and
        [IO.Path]::GetFileName($scriptPath) -like 'winutil-*.ps1'
    ) {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

# ──────────────────────────────────────────────────────────────────────────────

$sync["Form"].ShowDialog() | out-null
Remove-WinUtilTempScript
Stop-Transcript
