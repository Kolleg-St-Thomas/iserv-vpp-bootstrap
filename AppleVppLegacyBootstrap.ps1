#requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps a legacy Apple VPP license object for an unlimited free app.

.DESCRIPTION
    This workaround is intended for legacy MDM systems that discover Apps & Books
    through getVPPLicensesSrv instead of enumerating assets through getVPPAssetsSrv.

    The script:
      1. Reads an Apple School Manager location/content token from a file.
      2. Loads VPP assets.
      3. Loads the legacy VPP license records.
      4. Finds unlimited apps (totalCount = INT32_MAX) that have no legacy license record.
      5. Resolves their App Store names.
      6. Lets you select an app.
      7. Associates that app once with a designated "victim" iPad.
      8. Verifies that a legacy licenseIdStr was created.

    The script does NOT install the app on the iPad.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$BaseUrl = 'https://vpp.itunes.apple.com/mdm'
$UnlimitedCount = [int64]2147483647


function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Write-Title {
    Write-Host ''
    Write-Host 'Apple VPP Legacy Bootstrap' -ForegroundColor Cyan
    Write-Host '==========================' -ForegroundColor Cyan
    Write-Host ''
}

function Read-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    while ($true) {
        $path = (Read-Host $Prompt).Trim().Trim('"')

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }

        Write-Host 'Datei nicht gefunden. Bitte erneut eingeben.' -ForegroundColor Yellow
    }
}

function Invoke-VppPost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,

        [Parameter(Mandatory = $true)]
        [hashtable]$Body
    )

    $uri = "$BaseUrl/$Endpoint"
    $json = $Body | ConvertTo-Json -Depth 10 -Compress

    try {
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri $uri `
            -ContentType 'application/json' `
            -Body $json `
            -ErrorAction Stop
    }
    catch {
        throw "HTTP-Aufruf zu $Endpoint fehlgeschlagen: $($_.Exception.Message)"
    }

    $status = Get-OptionalProperty -Object $response -Name 'status'
    if ($null -eq $status -or [int]$status -ne 0) {
        $details = ''

        $errorMessage = Get-OptionalProperty -Object $response -Name 'errorMessage'
        $errorNumber = Get-OptionalProperty -Object $response -Name 'errorNumber'

        if ($null -ne $errorMessage) {
            $details = " - $errorMessage"
        }
        elseif ($null -ne $errorNumber) {
            $details = " - Apple-Fehler $errorNumber"
        }

        throw "Apple VPP meldet bei $Endpoint einen Fehler$details"
    }

    return $response
}

function Get-VppAssetsResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    return Invoke-VppPost -Endpoint 'getVPPAssetsSrv' -Body @{
        sToken               = $Token
        includeLicenseCounts = $true
    }
}

function Get-AllVppLicenses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    # Absichtlich derselbe ungefilterte Abruf, den das betroffene Legacy-MDM verwendet.
    # Apple kann große Antworten in mehrere Batches aufteilen.
    $licenses = New-Object System.Collections.Generic.List[object]
    $body = @{
        sToken = $Token
    }

    $lastBatchToken = $null

    for ($round = 1; $round -le 100; $round++) {
        $response = Invoke-VppPost -Endpoint 'getVPPLicensesSrv' -Body $body

        $responseLicenses = Get-OptionalProperty -Object $response -Name 'licenses'
        if ($null -ne $responseLicenses) {
            foreach ($license in @($responseLicenses)) {
                $licenses.Add($license)
            }
        }

        # Bei der letzten Seite liefert Apple sinceModifiedToken.
        # Bei Zwischen-Batches kann die Eigenschaft komplett fehlen.
        $sinceModifiedToken = Get-OptionalProperty -Object $response -Name 'sinceModifiedToken'
        if (-not [string]::IsNullOrWhiteSpace([string]$sinceModifiedToken)) {
            return $licenses.ToArray()
        }

        $batchToken = Get-OptionalProperty -Object $response -Name 'batchToken'
        $batchToken = [string]$batchToken

        # Manche Antworten passen vollständig in einen Batch und enthalten weder
        # batchToken noch sinceModifiedToken. Wenn batchCount/totalBatchCount zeigen,
        # dass alles geliefert wurde, ist das ebenfalls ein vollständiges Ergebnis.
        if ([string]::IsNullOrWhiteSpace($batchToken)) {
            $batchCount = Get-OptionalProperty -Object $response -Name 'batchCount'
            $totalBatchCount = Get-OptionalProperty -Object $response -Name 'totalBatchCount'

            if ($null -ne $batchCount -and $null -ne $totalBatchCount -and
                [int64]$batchCount -ge [int64]$totalBatchCount) {
                return $licenses.ToArray()
            }

            throw 'Apple hat weder batchToken noch sinceModifiedToken zurückgegeben. Der Lizenzabruf ist unvollständig.'
        }

        if ($batchToken -eq $lastBatchToken) {
            throw 'Apple hat denselben batchToken erneut zurückgegeben. Abbruch, um eine Endlosschleife zu vermeiden.'
        }

        $lastBatchToken = $batchToken
        $body = @{
            sToken     = $Token
            batchToken = $batchToken
        }
    }

    throw 'Mehr als 100 VPP-Batches empfangen. Abbruch aus Sicherheitsgründen.'
}

function Get-AppMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdamId,

        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    # Apples Legacy-MDM-Metadaten-Lookup.
    # Das Token als itvt-Cookie ermöglicht auch Metadaten für Inhalte,
    # die nicht im öffentlichen Store sichtbar sind.
    $encodedId = [Uri]::EscapeDataString($AdamId)
    $uri = "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup?version=2&id=$encodedId&p=mdm-lockup&caller=MDM&platform=volumestore&cc=de&l=de"

    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $uri `
            -Headers @{ Cookie = "itvt=$Token" } `
            -ErrorAction Stop

        $results = Get-OptionalProperty -Object $response -Name 'results'

        if ($null -ne $results) {
            $property = $results.PSObject.Properties |
                Where-Object { $_.Name -eq $AdamId } |
                Select-Object -First 1

            if ($null -ne $property) {
                $item = $property.Value
                $name = [string](Get-OptionalProperty -Object $item -Name 'name')

                if ([string]::IsNullOrWhiteSpace($name)) {
                    $name = [string](Get-OptionalProperty -Object $item -Name 'nameRaw')
                }

                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    return [PSCustomObject]@{
                        Name      = $name
                        Developer = [string](Get-OptionalProperty -Object $item -Name 'artistName')
                    }
                }
            }
        }
    }
    catch {
        # Fallback folgt unten.
    }

    # Fallback für öffentliche Apps über Apples iTunes Lookup API.
    try {
        $fallbackUri = "https://itunes.apple.com/lookup?id=$encodedId&country=de&entity=software"
        $fallback = Invoke-RestMethod -Method Get -Uri $fallbackUri -ErrorAction Stop
        $resultCount = Get-OptionalProperty -Object $fallback -Name 'resultCount'
        $results = Get-OptionalProperty -Object $fallback -Name 'results'

        if ($null -ne $resultCount -and [int]$resultCount -gt 0 -and $null -ne $results) {
            $item = @($results)[0]

            return [PSCustomObject]@{
                Name      = [string](Get-OptionalProperty -Object $item -Name 'trackName')
                Developer = [string](Get-OptionalProperty -Object $item -Name 'artistName')
            }
        }
    }
    catch {
        # Adam ID als letzter Fallback.
    }

    return [PSCustomObject]@{
        Name      = "Unbekannte App ($AdamId)"
        Developer = ''
    }
}

function Get-MissingUnlimitedApps {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Assets,

        [Parameter(Mandatory = $true)]
        [object[]]$Licenses,

        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $knownAdamIds = @{}

    foreach ($license in $Licenses) {
        $id = [string]$license.adamIdStr

        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $knownAdamIds[$id] = $true
        }
    }

    $missingAssets = @(
        $Assets | Where-Object {
            [int64]$_.totalCount -eq $UnlimitedCount -and
            [int]$_.productTypeId -eq 8 -and
            [bool]$_.deviceAssignable -eq $true -and
            -not $knownAdamIds.ContainsKey([string]$_.adamIdStr)
        }
    )

    $apps = New-Object System.Collections.Generic.List[object]

    foreach ($asset in $missingAssets) {
        $adamId = [string]$asset.adamIdStr
        $metadata = Get-AppMetadata -AdamId $adamId -Token $Token

        $apps.Add([PSCustomObject]@{
            Name         = $metadata.Name
            Developer    = $metadata.Developer
            AdamId       = $adamId
            PricingParam = [string]$asset.pricingParam
        })
    }

    return @($apps.ToArray() | Sort-Object Name, AdamId)
}

function Show-AppSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Apps
    )

    Write-Host ''
    Write-Host 'Apps ohne Legacy-Lizenzobjekt:' -ForegroundColor Cyan
    Write-Host ''

    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]

        Write-Host ('[{0}] {1}' -f ($i + 1), $app.Name) -ForegroundColor White

        $details = @()

        if (-not [string]::IsNullOrWhiteSpace([string]$app.Developer)) {
            $details += [string]$app.Developer
        }

        $details += "Adam ID $($app.AdamId)"
        Write-Host ('    ' + ($details -join ' · ')) -ForegroundColor DarkGray
    }

    Write-Host ''
}

function Read-AppSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Apps
    )

    while ($true) {
        $raw = (Read-Host 'Welche App soll dem Opfer-iPad zugewiesen werden?').Trim()
        $number = 0

        if ([int]::TryParse($raw, [ref]$number) -and
            $number -ge 1 -and
            $number -le $Apps.Count) {
            return ($number - 1)
        }

        Write-Host "Bitte eine Zahl zwischen 1 und $($Apps.Count) eingeben." -ForegroundColor Yellow
    }
}

function Associate-App {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$AdamId,

        [Parameter(Mandatory = $true)]
        [string]$PricingParam,

        [Parameter(Mandatory = $true)]
        [string]$SerialNumber
    )

    $body = @{
        sToken                 = $Token
        adamIdStr              = $AdamId
        associateSerialNumbers = @($SerialNumber)
    }

    if (-not [string]::IsNullOrWhiteSpace($PricingParam)) {
        $body.pricingParam = $PricingParam
    }

    return Invoke-VppPost -Endpoint 'manageVPPLicensesByAdamIdSrv' -Body $body
}

function Verify-Association {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$AdamId,

        [Parameter(Mandatory = $true)]
        [string]$SerialNumber
    )

    $response = Invoke-VppPost -Endpoint 'getVPPLicensesSrv' -Body @{
        sToken       = $Token
        adamId       = $AdamId
        assignedOnly = $true
    }

    $responseLicenses = Get-OptionalProperty -Object $response -Name 'licenses'

    foreach ($license in @($responseLicenses)) {
        if ([string](Get-OptionalProperty -Object $license -Name 'adamIdStr') -eq $AdamId -and
            [string](Get-OptionalProperty -Object $license -Name 'serialNumber') -eq $SerialNumber -and
            [string](Get-OptionalProperty -Object $license -Name 'status') -eq 'Associated') {
            return $license
        }
    }

    return $null
}

Write-Title

$tokenFile = Read-ExistingFile -Prompt 'Pfad zur Apple School Manager Content-Token-Datei'
$token = (Get-Content -LiteralPath $tokenFile -Raw).Trim()

if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Die Token-Datei ist leer.'
}

$serialNumber = ''

while ([string]::IsNullOrWhiteSpace($serialNumber)) {
    $serialNumber = (Read-Host 'Seriennummer des Opfer-iPads').Trim().ToUpperInvariant()
}

Write-Host ''
Write-Host 'VPP-Daten werden geladen ...' -ForegroundColor DarkGray

$assetsResponse = Get-VppAssetsResponse -Token $token
$assets = @(Get-OptionalProperty -Object $assetsResponse -Name 'assets')
$licenses = @(Get-AllVppLicenses -Token $token)

$location = Get-OptionalProperty -Object $assetsResponse -Name 'location'
$locationName = Get-OptionalProperty -Object $location -Name 'locationName'

if (-not [string]::IsNullOrWhiteSpace([string]$locationName)) {
    Write-Host ("Standort: {0}" -f $locationName) -ForegroundColor DarkGray
}

Write-Host ("Assets: {0} · Legacy-Lizenzobjekte: {1}" -f $assets.Count, $licenses.Count) -ForegroundColor DarkGray
Write-Host 'App-Namen werden aufgelöst ...' -ForegroundColor DarkGray

$apps = @(Get-MissingUnlimitedApps -Assets $assets -Licenses $licenses -Token $token)

if ($apps.Count -eq 0) {
    Write-Host ''
    Write-Host 'Keine Unlimited-App ohne Legacy-Lizenzobjekt gefunden.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

while ($apps.Count -gt 0) {
    Show-AppSelection -Apps $apps
    $selectedIndex = Read-AppSelection -Apps $apps
    $app = $apps[$selectedIndex]

    Write-Host ''
    Write-Host ("App:        {0}" -f $app.Name)
    Write-Host ("Opfer-iPad: {0}" -f $serialNumber)
    Write-Host ''

    $confirm = (Read-Host 'Diese App jetzt associaten? [J/n]').Trim()

    if ($confirm -match '^(n|nein|no)$') {
        Write-Host 'Abgebrochen.' -ForegroundColor Yellow
        break
    }

    Write-Host ''
    Write-Host 'Zuweisung wird erstellt ...' -ForegroundColor DarkGray

    try {
        $associationResponse = Associate-App `
            -Token $token `
            -AdamId $app.AdamId `
            -PricingParam $app.PricingParam `
            -SerialNumber $serialNumber

        $associations = Get-OptionalProperty -Object $associationResponse -Name 'associations'
        $association = @($associations) |
            Where-Object { [string](Get-OptionalProperty -Object $_ -Name 'serialNumber') -eq $serialNumber } |
            Select-Object -First 1

        if ($null -eq $association) {
            throw 'Apple meldet Erfolg, aber die erwartete Association fehlt in der Antwort.'
        }

        $verifiedLicense = Verify-Association `
            -Token $token `
            -AdamId $app.AdamId `
            -SerialNumber $serialNumber

        Write-Host ''
        Write-Host ('✓ {0} erfolgreich zugewiesen.' -f $app.Name) -ForegroundColor Green

        $verifiedLicenseId = Get-OptionalProperty -Object $verifiedLicense -Name 'licenseIdStr'
        $associationLicenseId = Get-OptionalProperty -Object $association -Name 'licenseIdStr'

        if (-not [string]::IsNullOrWhiteSpace([string]$verifiedLicenseId)) {
            Write-Host ('✓ Legacy License ID: {0}' -f $verifiedLicenseId) -ForegroundColor Green
        }
        elseif ($null -ne $associationLicenseId) {
            Write-Host ('✓ Legacy License ID: {0}' -f $associationLicenseId) -ForegroundColor Green
            Write-Host '  Die nachgelagerte Verifikation hat den Datensatz noch nicht zurückgeliefert.' -ForegroundColor Yellow
        }
        else {
            Write-Host '⚠ Apple hat keine Legacy License ID zurückgegeben.' -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ''
        Write-Host ('Fehler: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ''
        break
    }

    # Erfolgreich bearbeitete App lokal aus der Liste entfernen.
    $apps = @(
        for ($i = 0; $i -lt $apps.Count; $i++) {
            if ($i -ne $selectedIndex) {
                $apps[$i]
            }
        }
    )

    if ($apps.Count -eq 0) {
        Write-Host ''
        Write-Host 'Keine weiteren Apps ohne Legacy-Lizenzobjekt vorhanden.' -ForegroundColor Green
        break
    }

    Write-Host ''
    $again = (Read-Host 'Noch eine App auf dasselbe Opfer-iPad associaten? [j/N]').Trim()

    if ($again -notmatch '^(j|ja|y|yes)$') {
        break
    }
}

Write-Host ''
Write-Host 'Fertig. Danach im MDM die VPP-/Apps-&-Books-Synchronisierung starten.' -ForegroundColor Cyan
Write-Host ''
