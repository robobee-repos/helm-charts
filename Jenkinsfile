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
        label "maven-latest"
    }

    stages {

        /**
        * The stage will checkout the current branch.
        */
        stage("Checkout Build") {
            steps {
                container("maven") {
                    checkout scm
                }
            }
        }

        /**
        * The stage will setup the container for the build.
        */
        stage("Setup Build") {
            steps {
                container("maven") {
                    withCredentials([
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
    }
}
