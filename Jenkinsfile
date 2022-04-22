/**
 * Publishes the chars.
 *
 * @author Erwin Mueller, erwin.mueller@deventm.org
 * @since 1.0.0
 */

def harborLink = "https://harbor.anrisoftware.com/harbor/projects/2/helm-charts"
def destination = "helm-charts"

pipeline {

    options {
        buildDiscarder(logRotator(numToKeepStr: "3"))
        disableConcurrentBuilds()
        timeout(time: 60, unit: "MINUTES")
    }

    agent {
        label "helm"
    }

    stages {

        /**
        * Checkouts the current branch.
        */
        stage("Checkout Build") {
            steps {
                container("helm") {
                    checkout scm
                }
            }
        }

        /**
        * Publishs the helm charts.
        */
        stage("Publish") {
            steps {
                container("helm") {
                    withCredentials([
                        file(credentialsId: "PROJECT_SSH_HOST_FILE", variable: "PROJECT_SSH_HOST_FILE"),
                        string(credentialsId: "PROJECT_SSH_USER", variable: "PROJECT_SSH_USER"),
                        string(credentialsId: "PROJECT_SSH_PASS", variable: "PROJECT_SSH_PASS"),
                        file(credentialsId: "PROJECT_SSH_PRIVATE_FILE", variable: "PROJECT_SSH_PRIVATE_FILE"),
                        string(credentialsId: "PROJECT_GIT_NAME", variable: "PROJECT_GIT_NAME"),
                        string(credentialsId: "PROJECT_GIT_EMAIL", variable: "PROJECT_GIT_EMAIL"),
                        usernamePassword(credentialsId: "HELM_ROBOBEE_REPO_CREDENTIALS", usernameVariable: "HELM_REPO_USERNAME", passwordVariable: "HELM_REPO_PASSWORD")]) {
                        sh """
                            eval `ssh-agent -s`
                            /setup-ssh.sh
                            helm repo add robobeerun https://harbor.anrisoftware.com/chartrepo/robobeerun
                            helm repo update
                            git submodule init
                            git submodule update
                            make publish-harbor-all
                        """
                    }
                }
            }
        }
    }

    post {
        success {
            script {
                manager.createSummary("document.png").appendText("<a href='${harborLink}'>${destination}</a>", false)
            }
        }
    }
}
