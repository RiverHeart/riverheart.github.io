
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
        [string] $HomeTemplateFile = "templates/home.html"
    )

    if (Test-Path $OutputDirectory) {
        Remove-Item -Recurse -Force $OutputDirectory
    }

    New-Item -ItemType Directory -Path "$OutputDirectory/posts" -Force | Out-Null
    New-Item -ItemType File -Path "$OutputDirectory/.nojekyll" -Force | Out-Null
    Copy-Item -Path ./assets -Destination $OutputDirectory -Recurse -Force

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

            $ProcessedHtml = Format-HtmlCodeBlocks -InputObject $PostHtml

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
    Set-Content -Path "$OutputDirectory/index.html" -Value $IndexHtml

    Write-Host "Static site generation complete. Check the '$OutputDirectory' directory for output."
}

function New-Post {
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

function Remove-Post {
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

function Format-HtmlCodeBlocks {
    [CmdletBinding(DefaultParameterSetName="InputFile")]
    [OutputType([void], [string])]
    param(
        [Parameter(Mandatory,ParameterSetName="InputObject",ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [object] $InputObject,

        [Parameter(Mandatory,ParameterSetName="InputFile")]
        [ValidateNotNullOrEmpty()]
        [string] $InputFile,

        [ValidateNotNullOrEmpty()]
        [string] $OutputFile,

        [switch] $Overwrite
    )

    if ($PSCmdlet.ParameterSetName -eq "InputFile") {
        if (-not (Test-Path $InputFile)) {
            Write-Error "Input file '$InputFile' does not exist."
            return
        }

        $RawContent = Get-Content -Path $InputFile -Raw
        $HtmlContent = [xml] $RawContent
    } elseif ($PSCmdlet.ParameterSetName -eq "InputObject" -and $InputObject -is [string]) {
        $RawContent = $InputObject
        $HtmlContent = [xml] $RawContent
    } elseif ($PSCmdlet.ParameterSetName -eq "InputObject" -and $InputObject -is [xml]) {
        $HtmlContent = $InputObject
    } else {
        Write-Error "Invalid input object type. Must be a string or XML."
        return
    }

    # get code blocks from html
    $CodeBlocks = $HtmlContent.SelectNodes("//pre/code")
    foreach ($CodeBlock in $CodeBlocks) {
        # Add numbered lines by wrapping each line of code in a <span> element
        $CodeLines = $CodeBlock.InnerText -split "`r?`n"
        $Width = [Math]::Max(2, $CodeLines.Count.ToString().Length)
        $Counter = 1
        $Codeblock.InnerXml = (
            $CodeLines |
            ForEach-Object {
                $LineNumber = $Counter.ToString("D$Width")
                $EscapedLine = [System.Security.SecurityElement]::Escape($_)
                "<span class='line-number'>$LineNumber</span> $EscapedLine"
                $Counter++
            }
        ) -join "`n"
    }

    if ($Overwrite) { $OutputFile = $InputFile }
    
    if ($OutputFile) {
        $HtmlContent.OuterXml | Set-Content -Path $OutputFile
    } else {
        Write-Output $HtmlContent.OuterXml
    }
}


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