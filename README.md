# AWSCBManifestPS
Scaffolds a new PowerShell module project intended for CI/CD workflow using AWS CodeBuild



Configure GitHub Authentication
https://docs.aws.amazon.com/codepipeline/latest/userguide/GitHub-authentication.html



ProjectSource
https://docs.aws.amazon.com/codebuild/latest/APIReference/API_ProjectSource.html


For source code in a GitHub repository, the HTTPS clone URL to the repository that contains the source and the build spec. You must connect your AWS account to your GitHub account. Use the AWS CodeBuild console to start creating a build project. When you use the console to connect (or reconnect) with GitHub, on the GitHub Authorize application page, for Organization access, choose Request access next to each repository you want to allow AWS CodeBuild to have access to, and then choose Authorize application. (After you have connected to your GitHub account, you do not need to finish creating the build project. You can leave the AWS CodeBuild console.) To instruct AWS CodeBuild to use this connection, in the source object, set the auth object's type value to OAUTH.


AWS CodeBuild Project WebhookFilter
https://docs.amazonaws.cn/en_us/AWSCloudFormation/latest/UserGuide/aws-properties-codebuild-project-webhookfilter.html


For GitHub, the HTTPS clone URL to the repository that contains the source code and the build spec. The URL must contain "github.com." You must connect your AWS account to your GitHub account. To do this, use the CodeBuild console to create a build project.

    When you use the console to connect (or reconnect) with GitHub, on the GitHub Authorize application page, for Organization access, choose Request access next to each repository you want CodeBuild to be able to access.

    Choose Authorize application. (After you have connected to your GitHub account, you do not need to finish creating the build project. You can close the CodeBuild console.)

Filter GitHub Webhook Events
https://docs.aws.amazon.com/codebuild/latest/userguide/sample-github-pull-request.html#sample-github-pull-request-filter-webhook-events