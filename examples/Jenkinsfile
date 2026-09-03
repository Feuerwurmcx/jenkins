pipeline {
    agent any

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
    }

    parameters {
        booleanParam(name: 'BUILD_ALL', defaultValue: false,
                     description: 'Alle Pakete bauen statt nur der geänderten')
        booleanParam(name: 'SKIP_UPLOAD', defaultValue: false,
                     description: 'Nur packen, kein Nexus-Upload (Dry-Run)')
    }

    environment {
        NEXUS_URL     = 'https://nexus.example.com'
        // Upload geht IMMER ins hosted-Repo. Das group-Repo ist read-only und
        // nur zum Lesen da (pip install -i .../repository/<group>/simple/).
        NEXUS_PYPI_HOSTED = 'pypi-hosted'
        // Bewusst KEIN credentials() hier: das bindet das Secret für die gesamte
        // Pipeline, also auch für jeden Schritt, der es nichts angeht.
        NEXUS_CRED_ID = 'nexus-pypi-deploy'  // Username/Password-Credential in Jenkins
    }

    stages {

        stage('Setup') {
            steps {
                script {
                    // Basis für den Diff: letzter erfolgreicher Build (Git-Plugin setzt das),
                    // sonst HEAD~1, sonst leer -> alles bauen
                    def base = params.BUILD_ALL ? '' :
                        (env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: sh(returnStdout: true, script:
                            'git rev-parse HEAD~1 2>/dev/null || true').trim())

                    def out = sh(returnStdout: true, script: "bash ci/changed-packages.sh '${base}'").trim()
                    env.CHANGED = out
                    def pkgs = out ? out.split('\n') as List : []

                    echo "Basis   : ${base ?: '(keine – alles)'}"
                    echo "Pakete  : ${pkgs.join(', ') ?: '(keine Änderungen)'}"

                    if (pkgs.isEmpty()) {
                        currentBuild.result = 'SUCCESS'
                        currentBuild.description = 'keine Paketänderungen'
                    } else {
                        currentBuild.description = "${pkgs.size()} Paket(e): ${pkgs.join(', ')}"
                    }
                }
            }
        }

        stage('Pack & Publish') {
            when { expression { env.CHANGED?.trim() } }
            steps {
                script {
                    def pkgs = env.CHANGED.trim().split('\n') as List
                    def versions = [:]   // CPS-Branches laufen kooperativ, kein Sync nötig

                    parallel pkgs.collectEntries { pkg ->
                        [ (pkg): {
                            stage(pkg) {
                                // build-sdist.sh prueft die Version (PEP 440) und
                                // liefert den vom Build erzeugten Dateinamen zurueck –
                                // der wird NICHT selbst zusammengebaut, weil setuptools
                                // Name und Version normalisiert.
                                def archive = sh(returnStdout: true,
                                    script: "bash ci/build-sdist.sh '${pkg}'").trim()
                                // Aus PKG-INFO statt aus dem Dateinamen: Paketnamen
                                // dürfen selbst Bindestriche enthalten.
                                def version = sh(returnStdout: true,
                                    script: "bash ci/sdist-meta.sh '${archive}' version").trim()
                                def distName = sh(returnStdout: true,
                                    script: "bash ci/sdist-meta.sh '${archive}' name").trim()
                                echo "${pkg}: ${distName} ${version}"

                                if (params.SKIP_UPLOAD) {
                                    echo "SKIP_UPLOAD gesetzt – ${archive} nicht hochgeladen"
                                } else {
                                    // Secret nur für diesen einen sh-Schritt gebunden und
                                    // von Jenkins im Log maskiert. Es wird NICHT in den
                                    // Groovy-String interpoliert – das Skript liest es
                                    // selbst aus der Umgebung.
                                    withCredentials([usernamePassword(
                                            credentialsId: env.NEXUS_CRED_ID,
                                            usernameVariable: 'NEXUS_USER',
                                            passwordVariable: 'NEXUS_PASS')]) {
                                        sh "bash ci/publish-pypi.sh '${archive}'"
                                    }
                                }
                                versions[pkg] = "${distName} ${version}"
                            }
                        }]
                    }

                    currentBuild.description = versions.sort()
                        .collect { k, v -> v }.join(', ')
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'dist/*.tar.gz', allowEmptyArchive: true, fingerprint: true
        }
        cleanup {
            sh 'rm -rf dist'
        }
    }
}
