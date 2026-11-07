@{
    # Write-Host is used on purpose for progress messages in an interactive script.
    # The New-* functions only build text and objects; they change nothing.
    ExcludeRules = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions')
}
