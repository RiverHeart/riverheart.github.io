
function Build-Site {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [ValidateNotNullOrEmpty()]
        [string] $PostsDirectory = "posts",
        
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
            $Date = [DateTime]::Parse($DateString).ToString("yyyy-MM-dd")

            $ContentParts = $RawContent -split "---`r?`n"
            $PostContent = $ContentParts[2]

            # Create a new HTML file for the post
            $PostFileName = [System.IO.Path]::ChangeExtension($Post.Name, ".html")
            $PostFilePath = Join-Path -Path "$OutputDirectory/posts" -ChildPath $PostFileName

            $PostObject = ConvertFrom-Markdown -InputObject $PostContent

            # Replace placeholders in the master template with actual content
            $PostHtml = $Template -replace "{{\s*title\s*}}", $Title -replace "{{\s*content\s*}}", $PostObject.Html -replace "{{\s*date\s*}}", $Date

            # Write the final HTML to the new file
            Set-Content -Path $PostFilePath -Value $PostHtml

            # Add a link to the post in the post list
            $PostListHtml += "<li>$Date - <a href='posts/$PostFileName'>$Title</a></li>`n"
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

Build-Site