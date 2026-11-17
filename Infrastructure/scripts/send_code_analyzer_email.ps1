Param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$AttachmentPath
)

# --- Mail details ---
# This MUST be the Gmail address that owns the app password
$mailingFrom    = "p.gourav20022@gmail.com"
$recipients     = "gourav.pragvamsa.pattaswamy@pwc.com"  # can be comma-separated if needed
$mailingSubject = "Automated Salesforce Code Analyzer Report"
$mailBody       = @"
Hello Gourav,

Please find attached the latest Salesforce Code Analyzer report generated automatically by the Azure DevOps pipeline.

Regards,
Gourav 🤖
"@

# --- Validate attachment ---
if (-not (Test-Path $AttachmentPath)) {
    Write-Error "Attachment not found: $AttachmentPath"
    exit 1
}

# --- Get Gmail app password from environment variable ---
$gmailAppPassword = $env:GMAIL_APP_PASSWORD
if (-not $gmailAppPassword) {
    Write-Error "GMAIL_APP_PASSWORD environment variable not set."
    exit 1
}

# --- Build credential from app password ---
$securePassword = ConvertTo-SecureString $gmailAppPassword -AsPlainText -Force
$credential     = New-Object System.Management.Automation.PSCredential($mailingFrom, $securePassword)

# --- Mail parameters for Gmail SMTP ---
$mailParameters = @{
    From        = $mailingFrom
    To          = $recipients
    Subject     = $mailingSubject
    Body        = $mailBody
    Attachments = $AttachmentPath
    SmtpServer  = "smtp.gmail.com"
    Port        = 587
    UseSsl      = $true
    Credential  = $credential
}

# --- Attempt to send mail ---
try {
    Send-MailMessage @mailParameters
    Write-Host "✅ Email sent successfully to $recipients with attachment: $AttachmentPath"
} catch {
    Write-Error "❌ Failed to send email via Gmail SMTP: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        Write-Error "Inner exception: $($_.Exception.InnerException.Message)"
    }
    exit 1
}
