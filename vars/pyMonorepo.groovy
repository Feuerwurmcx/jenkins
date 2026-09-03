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
                        env.CI_LIB_DIR = materializeScripts('.ci-lib')

                        // Basis fuer den Diff: letzter erfolgreicher Build (Git-Plugin
                        // setzt das), sonst HEAD~1, sonst leer -> alles bauen.
                        def base = params.BUILD_ALL ? '' :
                            (env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: sh(returnStdout: true, script:
                                'git rev-parse HEAD~1 2>/dev/null || true').trim())

                        def out
                        // BASE geht wie PACKAGES per withEnv rein statt per String-
                        // Interpolation: env.GIT_PREVIOUS_SUCCESSFUL_COMMIT und das
                        // rev-parse-Ergebnis sind zwar meist ein Commit-Hash, aber
                        // letztlich Werte von ausserhalb dieses Skripts. Dieselbe
                        // Ueberlegung wie bei PKG/ARCHIVE unten in der naechsten
                        // Stage - konsequent auch hier, statt nur dort, wo es zuerst
                        // auffiel.
                        withEnv(["PACKAGES=${cfg.packages}", "BASE=${base}"]) {
                            out = sh(returnStdout: true, script:
                                'bash "$CI_LIB_DIR/changed-packages.sh" "$BASE"').trim()
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
                        def pkgs = env.CHANGED.trim().split('\n') as List
                        def versions = [:]   // CPS-Branches laufen kooperativ, kein Sync noetig

                        parallel pkgs.collectEntries { pkg ->
                            [ (pkg): {
                                stage(pkg) {
                                    def archive, version, distName

                                    // pkg ist ein Top-Level-Ordnername aus dem Monorepo -
                                    // von jedem Branch kontrollierbar, also nicht
                                    // vertrauenswuerdig. Deshalb NIE in den sh-String
                                    // interpolieren ('.../build-sdist.sh ${pkg}'), sondern
                                    // per withEnv als Shell-Variable durchreichen und im
                                    // Skript in doppelten Anfuehrungszeichen referenzieren
                                    // ("$PKG"). Sonst kann ein Ordnername wie
                                    // "x'; echo INJECTED >&2; '" einen zusaetzlichen
                                    // Shell-Befehl einschleusen. Exakt dieselbe Ueberlegung,
                                    // aus der das Nexus-Secret weiter unten schon heute nicht
                                    // interpoliert wird.
                                    withEnv(["PKG=${pkg}"]) {
                                        // build-sdist.sh liefert den vom Build erzeugten
                                        // Dateinamen zurueck - der wird NICHT selbst
                                        // zusammengebaut, weil setuptools Name und Version
                                        // normalisiert.
                                        archive = sh(returnStdout: true,
                                            script: 'bash "$CI_LIB_DIR/build-sdist.sh" "$PKG"').trim()
                                    }

                                    // archive kommt aus dem Dateinamen, den build-sdist.sh
                                    // erzeugt hat - letztlich also wieder aus pkg. Gleiche
                                    // Begruendung, gleicher Umweg ueber die Umgebung.
                                    withEnv(["ARCHIVE=${archive}"]) {
                                        // Aus PKG-INFO statt aus dem Dateinamen: Paketnamen
                                        // duerfen selbst Bindestriche enthalten.
                                        version = sh(returnStdout: true,
                                            script: 'bash "$CI_LIB_DIR/sdist-meta.sh" "$ARCHIVE" version').trim()
                                        distName = sh(returnStdout: true,
                                            script: 'bash "$CI_LIB_DIR/sdist-meta.sh" "$ARCHIVE" name').trim()
                                    }
                                    echo "${pkg}: ${distName} ${version}"

                                    if (params.SKIP_UPLOAD) {
                                        echo "SKIP_UPLOAD gesetzt – ${archive} nicht hochgeladen"
                                    } else {
                                        // Nexus-Werte und ARCHIVE nur um den Upload herum,
                                        // nicht global: dieselbe Ueberlegung wie beim Secret
                                        // unten.
                                        withEnv(["NEXUS_URL=${cfg.nexusUrl}",
                                                 "NEXUS_PYPI_HOSTED=${cfg.hostedRepo}",
                                                 "ARCHIVE=${archive}"]) {
                                            // Secret nur fuer diesen einen sh-Schritt gebunden
                                            // und von Jenkins im Log maskiert. Es wird NICHT in
                                            // den Groovy-String interpoliert - das Skript liest
                                            // es selbst aus der Umgebung.
                                            withCredentials([usernamePassword(
                                                    credentialsId: cfg.credentialsId,
                                                    usernameVariable: 'NEXUS_USER',
                                                    passwordVariable: 'NEXUS_PASS')]) {
                                                sh 'bash "$CI_LIB_DIR/publish-pypi.sh" "$ARCHIVE"'
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
// haelt es aus dem '*/'-Glob von changed-packages.sh heraus (Bash-Globs
// matchen versteckte Verzeichnisse ohne dotglob nicht) und faellt beim
// Durchsehen des Checkouts nicht auf. Als Paket wuerde targetDir ohnehin nie
// zaehlen, auch ohne den Punkt: all_packages() verlangt zusaetzlich
// pyproject.toml, setup.py oder __init__.py - die hier nie liegen.
//
// Aufgerufen wird immer als 'bash <pfad>': writeFile setzt kein
// Ausfuehrbar-Bit, und der Umweg ueber bash macht das auch unnoetig.
//
// Kein Default-Wert fuer targetDir: Groovy erzeugt fuer einen Default-Parameter
// eine synthetische parameterlose Ueberladung, und ob die wie der Rest dieser
// Methode CPS-transformiert wird (die Methode ruft mit writeFile/echo echte
// Pipeline-Steps auf), ist eine bekannte Fehlerquelle. Der Aufrufer uebergibt
// das Zielverzeichnis deshalb immer explizit.
private String materializeScripts(String targetDir) {
    List names = ['changed-packages.sh', 'build-sdist.sh', 'sdist-meta.sh', 'publish-pypi.sh']
    names.each { n ->
        writeFile file: "${targetDir}/${n}",
                  text: libraryResource("de/firma/ci/${n}"),
                  encoding: 'UTF-8'
    }
    echo "Skripte nach ${targetDir}/ geschrieben: ${names.join(', ')}"
    return targetDir
}
