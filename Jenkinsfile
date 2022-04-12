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
        * Setups the container for the build.
        */
        stage("Setup Build") {
            steps {
                container("helm") {
                    withCredentials([
                        file(credentialsId: "PROJECT_SSH_HOST_FILE", variable: "PROJECT_SSH_HOST_FILE"),
                        string(credentialsId: "PROJECT_SSH_USER", variable: "PROJECT_SSH_USER"),
                        string(credentialsId: "PROJECT_SSH_PASS", variable: "PROJECT_SSH_PASS"),
                        file(credentialsId: "PROJECT_SSH_PRIVATE_FILE", variable: "PROJECT_SSH_PRIVATE_FILE"),
                        string(credentialsId: "PROJECT_GIT_NAME", variable: "PROJECT_GIT_NAME"),
                        string(credentialsId: "PROJECT_GIT_EMAIL", variable: "PROJECT_GIT_EMAIL")]) {
                        sh "DEBUG=true /setup-ssh.sh"
                    }
                }
            }
        }

        /**
        * Deployes the helm charts.
        */
        stage("Deploy") {
            steps {
                container("helm") {
                    sh "make"
                }
            }
        }
    }
}
