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
                    sh """
                        export DEBUG="true"
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

    post {
        success {
            script {
                manager.createSummary("document.png").appendText("<a href='${harborLink}'>${destination}</a>", false)
            }
        }
    }
}
