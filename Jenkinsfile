/**
 * Publishes the chars.
 *
 * @author Erwin Mueller, erwin.mueller@deventm.org
 * @since 1.0.0
 */
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
                            DEBUG=true /setup-ssh.sh
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
}
