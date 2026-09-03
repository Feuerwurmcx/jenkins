// Standard-Pipeline fuer ein Python-Monorepo: geaenderte Pakete ermitteln, je
// eine sdist bauen und in ein Nexus-PyPI-hosted-Repo hochladen.
//
//   @Library('ci-shared@v1.0.0') _
//
//   pyMonorepo {
//       nexusUrl   = 'https://nexus.example.com'
//       hostedRepo = 'pypi-hosted'
//   }
//
// Die eigentliche Arbeit steckt in den Shell-Skripten unter
// resources/de/firma/ci/. Sie werden zur Laufzeit auf den Agent
// geschrieben - ein Monorepo braucht dadurch keinen ci/-Ordner mehr. Der
// Zuschnitt ist Absicht: was in .sh steckt, ist lokal testbar, was in Groovy
// steckt, erst auf einem Jenkins.

def call(Closure body) {
    Map cfg = [
        nexusUrl     : null,
        hostedRepo   : 'pypi-hosted',
        credentialsId: 'nexus-pypi-deploy',
        packages     : '',
        keepBuilds   : 30,
    ]
    body.resolveStrategy = Closure.DELEGATE_FIRST
    body.delegate = cfg
    body()

    if (!cfg.nexusUrl) {
        error 'pyMonorepo: nexusUrl fehlt - Basis-URL der Nexus-Instanz setzen'
    }

    pipeline {
        agent any

        options {
            timestamps()
            buildDiscarder(logRotator(numToKeepStr: "${cfg.keepBuilds}"))
            disableConcurrentBuilds()
        }

        parameters {
            booleanParam(name: 'BUILD_ALL', defaultValue: false,
                         description: 'Alle Pakete bauen statt nur der geänderten')
            booleanParam(name: 'SKIP_UPLOAD', defaultValue: false,
                         description: 'Nur bauen, kein Upload (Dry-Run)')
        }

        stages {

            stage('Setup') {
                steps {
                    script {
                        // Ueber env statt ueber eine lokale Variable: der Pfad wird in
                        // einer spaeteren Stage und im post-Block wieder gebraucht.
                        env.CI_LIB_DIR = materializeScripts()

                        // Basis fuer den Diff: letzter erfolgreicher Build (Git-Plugin
                        // setzt das), sonst HEAD~1, sonst leer -> alles bauen.
                        def base = params.BUILD_ALL ? '' :
                            (env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: sh(returnStdout: true, script:
                                'git rev-parse HEAD~1 2>/dev/null || true').trim())

                        def out
                        withEnv(["PACKAGES=${cfg.packages}"]) {
                            out = sh(returnStdout: true, script:
                                "bash ${env.CI_LIB_DIR}/changed-packages.sh '${base}'").trim()
                        }
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
                        def dir  = env.CI_LIB_DIR
                        def pkgs = env.CHANGED.trim().split('\n') as List
                        def versions = [:]   // CPS-Branches laufen kooperativ, kein Sync noetig

                        parallel pkgs.collectEntries { pkg ->
                            [ (pkg): {
                                stage(pkg) {
                                    // build-sdist.sh liefert den vom Build erzeugten
                                    // Dateinamen zurueck - der wird NICHT selbst
                                    // zusammengebaut, weil setuptools Name und Version
                                    // normalisiert.
                                    def archive = sh(returnStdout: true,
                                        script: "bash ${dir}/build-sdist.sh '${pkg}'").trim()
                                    // Aus PKG-INFO statt aus dem Dateinamen: Paketnamen
                                    // duerfen selbst Bindestriche enthalten.
                                    def version = sh(returnStdout: true,
                                        script: "bash ${dir}/sdist-meta.sh '${archive}' version").trim()
                                    def distName = sh(returnStdout: true,
                                        script: "bash ${dir}/sdist-meta.sh '${archive}' name").trim()
                                    echo "${pkg}: ${distName} ${version}"

                                    if (params.SKIP_UPLOAD) {
                                        echo "SKIP_UPLOAD gesetzt – ${archive} nicht hochgeladen"
                                    } else {
                                        // Nexus-Werte nur um den Upload herum, nicht global:
                                        // dieselbe Ueberlegung wie beim Secret unten.
                                        withEnv(["NEXUS_URL=${cfg.nexusUrl}",
                                                 "NEXUS_PYPI_HOSTED=${cfg.hostedRepo}"]) {
                                            // Secret nur fuer diesen einen sh-Schritt gebunden
                                            // und von Jenkins im Log maskiert. Es wird NICHT in
                                            // den Groovy-String interpoliert - das Skript liest
                                            // es selbst aus der Umgebung.
                                            withCredentials([usernamePassword(
                                                    credentialsId: cfg.credentialsId,
                                                    usernameVariable: 'NEXUS_USER',
                                                    passwordVariable: 'NEXUS_PASS')]) {
                                                sh "bash ${dir}/publish-pypi.sh '${archive}'"
                                            }
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
                archiveArtifacts artifacts: 'dist/*.tar.gz',
                                 allowEmptyArchive: true, fingerprint: true
            }
            cleanup {
                sh 'rm -rf dist'
                script {
                    if (env.CI_LIB_DIR) {
                        sh "rm -rf '${env.CI_LIB_DIR}'"
                    }
                }
            }
        }
    }
}

// Schreibt die Skripte aus resources/ auf den Agent und gibt das Verzeichnis
// zurueck. libraryResource liefert nur den Dateiinhalt als String - resources/
// selbst liegt nie auf dem Agent.
//
// Das Ziel liegt im Checkout, faellt dort aber nicht auf: der fuehrende Punkt
// haelt es aus dem '*/'-Glob von changed-packages.sh heraus, und ungetrackt
// taucht es auch im git diff nicht auf. Ein Ordner ohne Punkt waere hier
// falsch - er wuerde als moegliches Paket mitgezaehlt.
//
// Aufgerufen wird immer als 'bash <pfad>': writeFile setzt kein
// Ausfuehrbar-Bit, und der Umweg ueber bash macht das auch unnoetig.
private String materializeScripts(String targetDir = '.ci-lib') {
    List names = ['changed-packages.sh', 'build-sdist.sh', 'sdist-meta.sh', 'publish-pypi.sh']
    names.each { n ->
        writeFile file: "${targetDir}/${n}",
                  text: libraryResource("de/firma/ci/${n}"),
                  encoding: 'UTF-8'
    }
    echo "Skripte nach ${targetDir}/ geschrieben: ${names.join(', ')}"
    return targetDir
}
