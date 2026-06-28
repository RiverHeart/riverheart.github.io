
<#
.NOTES
    If XmlWriter fails to indent things properly it's likely because the input contains
    mixed content(text nodes and element nodes) in a way that makes it impossible to indent
    properly. Ensure that all text nodes are wrapped in elements so they do not trigger mixed
    content mode.
#>
function Build-Site {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [ValidateNotNullOrEmpty()]
        [string] $PostsDirectory = "posts",

        [ValidateNotNullOrEmpty()]
        [string] $PagesDirectory = "pages",
        
        [ValidateNotNullOrEmpty()]
        [string] $OutputDirectory = "docs",

        [ValidateNotNullOrEmpty()]
        [string] $TemplateFile = "templates/layout.html",

        [ValidateNotNullOrEmpty()]
        [string] $HomeTemplateFile = "templates/home.html",

        [ValidateNotNullOrEmpty()]
        [string] $AssetsDirectory = "assets",

        [ValidateNotNullOrEmpty()]
        [string] $ConfigFile = "$PSScriptRoot/ssg.json"
    )

    $XmlWriterSettings = [System.Xml.XmlWriterSettings]::new()
    $XmlWriterSettings.Indent = $true
    $XmlWriterSettings.IndentChars = "  "
    $XmlWriterSettings.OmitXmlDeclaration = $true

    if (Test-Path $OutputDirectory) {
        Remove-Item -Recurse -Force $OutputDirectory
    }

    try {
        $ssgConfig = Get-Content -Path "$ConfigFile" | ConvertFrom-Json
    } catch {
        Write-Error "Could not read '$ConfigFile'. Ensure it exists and is valid JSON."
        return
    }

    New-Item -ItemType Directory -Path "$OutputDirectory/posts" -Force | Out-Null
    New-Item -ItemType File -Path "$OutputDirectory/.nojekyll" -Force | Out-Null
    Copy-Item -Path "$AssetsDirectory" -Destination $OutputDirectory -Recurse -Force

    # Copy static standalone pages (about.html, uses.html, etc.) if present.
    if (Test-Path $PagesDirectory) {
        Copy-Item -Path "$PagesDirectory/*" -Destination $OutputDirectory -Recurse -Force
    }

    $Template = Get-Content -Path $TemplateFile -Raw

    $Posts = Get-ChildItem -Path $PostsDirectory -Filter "*.md" | Sort-Object LastWriteTime -Descending
    $PostListHtml = ""

    if ($Posts.Count -eq 0) {
        Write-Warning "No posts found in the '$PostsDirectory' directory."
    } else {
        Write-Host "Processing ($($Posts.Count)) posts..."

        # Prepare to rebuild the titles catalog
        $Titles = [string[]]@()

        foreach ($Post in $Posts) {
            $RawContent = Get-Content -Path $Post.FullName -Raw
            $PostHtml = ConvertFrom-Markdown -InputObject $RawContent

            # Extract the title from the first line of the markdown file
            $Lines = $RawContent -split "`r?`n"
            $Title = ($Lines | Where-Object { $_ -match "^title:\s*(.*)" }) -replace "^title:\s*", ""
            $Titles += $Title
            $Description = ($Lines | Where-Object { $_ -match "^description:\s*(.*)" }) -replace "^description:\s*", ""
            $DateString = ($Lines | Where-Object { $_ -match "^date:\s*(.*)" }) -replace "^date:\s*", ""
            $PostDate = [DateTimeOffset]::Parse($DateString)
            $DateForPost = $PostDate.ToString("MMM d, yyyy 'at' h:mm tt zzz")
            $DateForList = $PostDate.ToString("yyyy-MM-dd")

            # To avoid splitting on the wrong "---" in the content, we will split only on the first two occurrences of "---"
            $ContentParts = $RawContent -split "---`r?`n", 3
            $PostContent = $ContentParts[2]

            # Create a new HTML file for the post
            $PostFileName = [System.IO.Path]::ChangeExtension($Post.Name, ".html")
            $PostFilePath = Join-Path -Path "$OutputDirectory/posts" -ChildPath $PostFileName

            $PostObject = ConvertFrom-Markdown -InputObject $PostContent

            # Replace placeholders in the master template with actual content
            $PostHtml = $Template `
                -replace "{{\s*title\s*}}", $Title `
                -replace "{{\s*content\s*}}", $PostObject.Html `
                -replace "{{\s*date\s*}}", $DateForPost

            # TODO: Formatting issue. PostHtml looks fine but the ProcessedHtml output is not indented properly.
            # I might not need to use XmlWriter at all if this can be fixed. It's better that XmlWriter not be
            # used since it's putting the codeblock spans on newlines and breaking the layout.
            $ProcessedHtml = Format-HtmlCode $PostHtml

            #$PostDocument = [System.Xml.Linq.XDocument]::Parse("$ProcessedHtml")

            # if ($null -eq $PostDocument.SelectSingleNode("//head")) {
            #     $HeadNode = $PostDocument.CreateElement("head")
            #     $PostDocument.DocumentElement.PrependChild($HeadNode) | Out-Null
            # } else {
            #     $HeadNode = $PostDocument.SelectSingleNode("//head")
            # }

            # # Add open graph meta tags for social media sharing
            # $HeadNode.AppendChild($PostDocument.CreateElement("meta")).SetAttribute("property", "og:title")
            # $HeadNode.LastChild.SetAttribute("content", $Title)
            # $HeadNode.AppendChild($PostDocument.CreateElement("meta")).SetAttribute("property", "og:description")
            # $HeadNode.LastChild.SetAttribute("content", $Description)
            # $HeadNode.AppendChild($PostDocument.CreateElement("meta")).SetAttribute("property", "og:type")
            # $HeadNode.LastChild.SetAttribute("content", "article")
            # $HeadNode.AppendChild($PostDocument.CreateElement("meta")).SetAttribute("property", "og:url")
            # $HeadNode.LastChild.SetAttribute("content", "$($ssgConfig.url)/posts/$PostFileName")

            # Write the final HTML to the new file
            Set-Content -Path $PostFilePath -Value $ProcessedHtml

            # Add a link to the post in the post list
            $PostListHtml += "<li>$DateForList - <a href='posts/$PostFileName'>$Title</a></li>`n"
        }

        Export-Clixml -InputObject $Titles -Path "$PostsDirectory/titles.clixml"
    }

    # Generate the index.html file with the list of posts
    $HomeTemplate = Get-Content -Path $HomeTemplateFile -Raw
    $IndexHtml = $HomeTemplate -replace "{{\s*title\s*}}", "Home" -replace "{{\s*posts\s*}}", $PostListHtml

    try {
        $XmlWriter = [System.Xml.XmlWriter]::Create("$OutputDirectory/index.html", $XmlWriterSettings)
        $XmlWriter.WriteRaw($IndexHtml)
    } catch {
        Write-Error "Failed to write index.html: $_"
    } finally {
        if ($XmlWriter) {
            $XmlWriter.Close()
        }
    }

    Write-Host "Static site generation complete. Check the '$OutputDirectory' directory for output."
}

function New-BlogPost {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [ValidateLength(1, 150)]
        [string] $Description,

        [ValidateNotNullOrEmpty()]
        [string] $PostsDirectory = "posts"
    )

    if (-not (Test-Path $PostsDirectory)) {
        New-Item -ItemType Directory -Path $PostsDirectory -Force | Out-Null
    }

    # Rather than looping through all exists posts, maintain a separate catalog for fast lookups
    if (Test-Path "$PostsDirectory/titles.clixml") {
        $ExistingTitles = Import-Clixml -Path "$PostsDirectory/titles.clixml"
        if ($ExistingTitles -contains $Title) {
            Write-Warning "A post with the title '$Title' already exists."
            return
        }
    } else {
        $ExistingTitles = [string[]]@()
    }

    $DateRaw = Get-Date
    $DatePrefix = $DateRaw.ToString("yyyy-MM-dd_HHmmss")  # For chronological ordering in filenames
    $DateExact = $DateRaw.ToString("yyyy-MM-ddTHH:mm:ssK")
    $FileName = "$DatePrefix-$($Title -replace '\s+', '-').md"
    $FilePath = Join-Path -Path $PostsDirectory -ChildPath $FileName

    if (Test-Path $FilePath) {
        Write-Error "A post named '$FileName' already exists."
        return
    }

    Set-Content -Path $FilePath -Value @"
---
title: $Title
date: $DateExact
description: $Description
---

Your content here...
"@

    # Update the titles file
    $ExistingTitles += $Title
    $ExistingTitles | Export-Clixml -Path "$PostsDirectory/titles.clixml"

    Write-Host "Post created at '$FilePath'."

    # Open the new post in the default editor if available
    if ($env:EDITOR) {
        & $env:EDITOR $FilePath
    }
}

function Remove-BlogPost {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [ValidateNotNullOrEmpty()]
        [string] $PostsDirectory = "posts"
    )

    if (-not (Test-Path $PostsDirectory)) {
        Write-Warning "The posts directory '$PostsDirectory' does not exist."
        return
    }

    # Load existing titles
    if (Test-Path "$PostsDirectory/titles.clixml") {
        $ExistingTitles = Import-Clixml -Path "$PostsDirectory/titles.clixml"
    } else {
        Write-Warning "No titles catalog found. Cannot remove post."
        return
    }

    if (-not ($ExistingTitles -contains $Title)) {
        Write-Warning "No post with the title '$Title' exists."
        return
    }

    # Find the corresponding file
    $PostFile = Get-ChildItem -Path $PostsDirectory -Filter "*.md" | Where-Object {
        $RawContent = Get-Content -Path $_.FullName -Raw
        ($RawContent -split "`r?`n" | Where-Object { $_ -match "^title:\s*(.*)" }) -replace "^title:\s*", "" -eq $Title
    }

    if ($PostFile) {
        Remove-Item -Path $PostFile.FullName -Force
        Write-Host "Removed post '$Title' at '$($PostFile.FullName)'."

        # Update the titles file
        $UpdatedTitles = $ExistingTitles | Where-Object { $_ -ne $Title }
        $UpdatedTitles | Export-Clixml -Path "$PostsDirectory/titles.clixml"
    } else {
        Write-Warning "Could not find the file for the post titled '$Title'."
    }
}

<#
.NOTES
    We can't cast the input to [xml] and work on OuterXML because it'll screw up the formatting of the entire
    document. We'll need to isolate the code blocks, format them, and then replace them in the original HTML string.
#>
function Format-HtmlCode {
    [CmdletBinding()]
    [OutputType([void], [string])]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string] $Html
    )

    # Parse code blocks from the HTML content without xml
    $WeAreInsideCodeBlock = $false
    $StringBuilder = [System.Text.StringBuilder]::new()
    $CodeBlock = [System.Collections.Generic.List[string]]::new()

    foreach($Line in $Html -split "`r?`n") {
        $OpeningTag, $RestOfLine = $null, $null

        if ($Line -match "<pre><code.*?>") {
            $WeAreInsideCodeBlock = $true
            $CodeBlock.Clear() | Out-Null

            # Split the line to separate the opening <pre><code> tag from the rest of the content
            $OpeningTag, $RestOfLine = $Line -split "(?<=<pre><code.*?>)", 2
            if ($OpeningTag) {
                $StringBuilder.AppendLine($OpeningTag) | Out-Null
            }
            if ($RestOfLine) {
                $CodeBlock.Add($RestOfLine) | Out-Null
            }
        } elseif ($Line -match "</code></pre>") {
            $WeAreInsideCodeBlock = $false
            # Split the line to separate the closing </code></pre> tag from the rest of the content
            $RestOfLine, $ClosingTag = $Line -split "(?=</code></pre>)", 2
            if ($RestOfLine) {
                $CodeBlock.Add($RestOfLine) | Out-Null
            }

            # Process the code block content
            (Format-HtmlCodeBlock $CodeBlock) | Foreach-Object {
                $StringBuilder.AppendLine($_) | Out-Null
            }

            if ($ClosingTag) {
                $StringBuilder.AppendLine($ClosingTag) | Out-Null
            }
        } elseif ($WeAreInsideCodeBlock) {
            $CodeBlock.Add($Line) | Out-Null
        } else {
            $StringBuilder.AppendLine($Line) | Out-Null
        }
    }
    return $StringBuilder.ToString()
}

function Format-HtmlCodeBlock {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string]])]
    param(
        [System.Collections.Generic.List[string]] $CodeBlock
    )

    $Width = [Math]::Max(2, $CodeBlock.Count.ToString().Length)
    $Counter = 1
    foreach ($Line in $CodeBlock) {
        $LineNumber = $Counter.ToString("D$Width")
        $EscapedLine = [System.Security.SecurityElement]::Escape($Line)
        $FormattedLine = "<span class='line-number'>$LineNumber</span> $EscapedLine"
        $Counter++
        Write-Output $FormattedLine
    }
}


# TODO: Grab powershell.tmLanguage from the VSCode extension and use it to highlight code blocks.
function Apply-SyntaxHighlighting {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $InputFile,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputFile
    )

    if (-not (Test-Path $InputFile)) {
        Write-Error "Input file '$InputFile' does not exist."
        return
    }

    $RawContent = Get-Content -Path $InputFile -Raw
    $HighlightedContent = ConvertFrom-Markdown -InputObject $RawContent
    $HtmlContent = [xml] $HighlightedContent.Html
    # get code blocks from html
    $CodeBlocks = $HtmlContent.SelectNodes("//pre/code")
    foreach ($CodeBlock in $CodeBlocks) {
        $Language = $CodeBlock.GetAttribute("class")
        if ($Language -match "language-(\w+)") {
            $Lang = $Matches[1]
            # Use Pygments or any other syntax highlighter here
            # For demonstration, we'll just wrap it in a div with the language class
            $CodeBlock.ParentNode.InnerXml = "<div class='highlight $Lang'>$($CodeBlock.InnerXml)</div>"
        }
    }
    $HtmlContent.OuterXml | Set-Content -Path $OutputFile
}

build-site