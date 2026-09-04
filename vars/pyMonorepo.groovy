// Jenkins Shared Library fuer ein Python-Monorepo: geaenderte Pakete ermitteln,
// je eine sdist bauen und in ein Nexus-PyPI-hosted-Repo hochladen.
//
// Drei Arten, es zu benutzen:
//
//   1) Vollpipeline (neues Monorepo, Jenkinsfile enthaelt nur Konfiguration):
//        @Library('ci-shared@v1.0.0') _
//        pyMonorepo { nexusUrl = 'https://nexus.example.com'; hostedRepo = 'pypi-hosted' }
//
//   2) Composite-Step in einer Stage einer BESTEHENDEN Pipeline:
//        script { pyMonorepo.build(nexusUrl: '...', hostedRepo: 'pypi-hosted') }
//
//   3) Einzel-Steps, wenn eine Pipeline abweichen muss:
//        pyMonorepo.install()
//        def pkgs = pyMonorepo.changedPackages(base)
//        def a = pyMonorepo.buildSdist(pkg); def v = pyMonorepo.meta(a, 'version')
//        pyMonorepo.publish(archive: a, nexusUrl: '...')
//        pyMonorepo.cleanup()
//
// Die eigentliche Arbeit steckt in den Shell-Skripten unter resources/de/firma/ci/.
// Sie werden zur Laufzeit per install() auf den Agent geschrieben - ein Monorepo
// braucht keinen ci/-Ordner. Was in .sh steckt, ist lokal testbar; was in
// Groovy steckt, erst auf einem Jenkins. Deshalb bleibt Groovy duenn.
//
// Disziplin, die in JEDEM Step gilt: vom Repo kontrollierte Werte (Paketname,
// Archivpfad, Basis-Commit, Paketliste) gehen per withEnv in die Umgebung, der
// sh-String ist einfach gequotet und referenziert die Shell-Variable. Nie
// Groovy-Interpolation in einen sh-String - ein Ordnername wie
// "x'; echo INJECTED >&2; '" wuerde sonst Kommandos einschleusen.
//
// Keine Default-Parameter: Groovy erzeugt daraus eine synthetische Ueberladung,
// deren CPS-Transformation eine bekannte Fehlerquelle ist. Wo ein Default
// gewuenscht ist, gibt es zwei explizite Ueberladungen.

// ---------------------------------------------------------------------------
// Vollpipeline-Wrapper
// ---------------------------------------------------------------------------

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
            stage('Build') {
                steps {
                    script {
                        // Archivieren und Aufraeumen macht der post-Block unten -
                        // der laeuft auch, wenn build() abbricht.
                        // this.build(): 'build' ist auch ein globaler Step
                        // (pipeline-build-step-Plugin) - ohne 'this.' waere
                        // der Aufruf zweideutig, symmetrisch zu this.cleanup()
                        // im post-Block unten.
                        this.build(nexusUrl: cfg.nexusUrl, hostedRepo: cfg.hostedRepo,
                                   credentialsId: cfg.credentialsId, packages: cfg.packages,
                                   archive: false, cleanup: false)
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
                // this.cleanup(): im post-Block heisst 'cleanup' schon der
                // umschliessende Post-Condition-Block - ohne 'this.' waere
                // der Aufruf zweideutig zwischen der Closure und dem Step.
                script { this.cleanup() }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Composite-Step fuer bestehende Pipelines
// ---------------------------------------------------------------------------

// Der ganze Ablauf in EINER Stage des Aufrufers:
//
//   stage('Pakete') { steps { script {
//       pyMonorepo.build(nexusUrl: 'https://nexus...', hostedRepo: 'pypi-hosted')
//   } } }
//
// Argumente (alle ausser nexusUrl optional):
//   hostedRepo, credentialsId, packages  - wie in der Vollpipeline
//   buildAll, skipUpload  - Argument gewinnt; fehlt es, params.BUILD_ALL /
//                           params.SKIP_UPLOAD, falls die Pipeline sie hat; sonst false
//   base                  - Diff-Basis; fehlt sie, wie ueblich berechnet
//   archive (true)        - dist/*.tar.gz am Ende archivieren
//   cleanup (true)        - dist/ und .ci-lib/ am Ende entfernen
// archive/cleanup auf false setzen, wenn der eigene post-Block das uebernimmt
// (dann dort pyMonorepo.cleanup() aufrufen). Rueckgabe: Paket -> "name version".
//
// Fuer Abbruchfestigkeit (Timeout/Abort): archive: false, cleanup: false
// setzen und einen eigenen post-Block ergaenzen, der pyMonorepo.cleanup()
// aufruft - Steps im finally dieser Methode laufen bei Abbruch/Timeout nicht
// zuverlaessig. So macht es die Vollpipeline (call()) oben.
Map build(Map args) {
    List allowed = ['nexusUrl', 'hostedRepo', 'credentialsId', 'packages', 'buildAll', 'skipUpload', 'base', 'archive', 'cleanup']
    List unknown = []
    for (String k : args.keySet()) {
        if (!(k in allowed)) { unknown << k }
    }
    if (unknown) {
        error "pyMonorepo.build: unbekannte Argumente ${unknown} - erlaubt: ${allowed}"
    }
    if (!args.nexusUrl) {
        error 'pyMonorepo.build: nexusUrl fehlt - Basis-URL der Nexus-Instanz setzen'
    }
    boolean doArchive  = args.containsKey('archive')    ? toBool(args.archive, true)     : true
    boolean doCleanup  = args.containsKey('cleanup')    ? toBool(args.cleanup, true)     : true
    boolean buildAll   = args.containsKey('buildAll')   ? toBool(args.buildAll, false)   : paramOr('BUILD_ALL', false)
    boolean skipUpload = args.containsKey('skipUpload') ? toBool(args.skipUpload, false) : paramOr('SKIP_UPLOAD', false)
    String hostedRepo    = args.hostedRepo    ?: 'pypi-hosted'
    String credentialsId = args.credentialsId ?: 'nexus-pypi-deploy'
    Map versions = [:]   // CPS-Branches laufen kooperativ, kein Sync noetig

    try {
        install()
        String base = args.containsKey('base') ? (args.base ?: '') : (buildAll ? '' : defaultBase())
        List pkgs = changedPackages(base, args.packages ?: '')

        echo "Basis   : ${base ?: '(keine – alles)'}"
        echo "Pakete  : ${pkgs.join(', ') ?: '(keine Änderungen)'}"

        if (pkgs.isEmpty()) {
            currentBuild.description = 'keine Paketänderungen'
            return versions
        }
        currentBuild.description = "${pkgs.size()} Paket(e): ${pkgs.join(', ')}"

        parallel pkgs.collectEntries { pkg ->
            [ (pkg): {
                stage(pkg) {
                    String archive  = buildSdist(pkg)
                    String distName = meta(archive, 'name')
                    String version  = meta(archive, 'version')
                    echo "${pkg}: ${distName} ${version}"

                    if (skipUpload) {
                        echo "SKIP_UPLOAD/skipUpload gesetzt – ${archive} nicht hochgeladen"
                    } else {
                        publish(archive: archive, nexusUrl: args.nexusUrl,
                                hostedRepo: hostedRepo, credentialsId: credentialsId)
                    }
                    versions[pkg] = "${distName} ${version}"
                }
            }]
        }

        currentBuild.description = versions.sort().collect { k, v -> v }.join(', ')
        return versions
    } finally {
        // Bei Abort/Timeout sind Steps im finally unzuverlaessig; eine
        // Exception hier (z.B. rm -rf bei Agent-Verlust) darf nicht die
        // eigentliche Ursache aus dem try-Block verdecken (I-5).
        try {
            // Erst archivieren, dann aufraeumen - sonst ist dist/ schon weg.
            if (doArchive) {
                archiveArtifacts artifacts: 'dist/*.tar.gz', allowEmptyArchive: true, fingerprint: true
            }
            if (doCleanup) {
                cleanup()
            }
        } catch (Exception e) {
            echo "pyMonorepo.build: Aufraeumen fehlgeschlagen: ${e}"
        }
    }
}

// ---------------------------------------------------------------------------
// Einzel-Steps
// ---------------------------------------------------------------------------

// Schreibt die Skripte aus resources/ nach libDir() und merkt sich den Pfad in
// env.CI_LIB_DIR - env, nicht lokale Variable, damit spaetere Stages und der
// post-Block ihn sehen. libraryResource liefert nur den Dateiinhalt als String;
// resources/ selbst liegt nie auf dem Agent.
//
// Aufgerufen wird immer als 'bash <pfad>': writeFile setzt kein Ausfuehrbar-Bit,
// und der Umweg ueber bash macht das auch unnoetig. Idempotent.
String install() {
    String dir = libDir()
    List names = ['changed-packages.sh', 'build-sdist.sh', 'sdist-meta.sh', 'publish-pypi.sh']
    for (String n : names) {
        writeFile file: "${dir}/${n}",
                  text: libraryResource(resource: "de/firma/ci/${n}", encoding: 'UTF-8'),
                  encoding: 'UTF-8'
    }
    env.CI_LIB_DIR = dir
    echo "Skripte nach ${dir}/ geschrieben: ${names.join(', ')}"
    return dir
}

// Geaenderte Pakete seit base; leere Basis heisst "alle". Auto-Erkennung der
// Paketordner (siehe changed-packages.sh).
List changedPackages(String base) {
    return changedPackages(base, '')
}

// Wie oben, aber mit fester Paketliste (Leerzeichen-getrennt) statt
// Auto-Erkennung. Leeres packages = Auto-Erkennung.
List changedPackages(String base, String packages) {
    requireInstalled()
    String out
    withEnv(["BASE=${base ?: ''}", "PACKAGES=${packages ?: ''}"]) {
        out = sh(returnStdout: true,
                 script: 'bash "$CI_LIB_DIR/changed-packages.sh" "$BASE"').trim()
    }
    return out ? (out.split('\n') as List) : []
}

// Baut die sdist eines Paketordners und gibt den Pfad zurueck, den das Skript
// meldet (dist/<datei>). Der Dateiname wird NICHT selbst zusammengebaut, weil
// setuptools Name und Version normalisiert.
String buildSdist(String pkg) {
    requireInstalled()
    String archive
    withEnv(["PKG=${pkg}"]) {
        archive = sh(returnStdout: true,
                     script: 'bash "$CI_LIB_DIR/build-sdist.sh" "$PKG"').trim()
    }
    return archive
}

// Name oder Version aus der PKG-INFO der sdist - nicht aus dem Dateinamen,
// weil Paketnamen selbst Bindestriche enthalten duerfen. field ist auf die
// Whitelist begrenzt und geht trotzdem per withEnv rein: die Whitelist ist eine
// zweite Sicherung, keine Alternative zur Disziplin.
String meta(String archive, String field) {
    requireInstalled()
    if (!(field in ['name', 'version'])) {
        error "pyMonorepo.meta: field muss 'name' oder 'version' sein, war '${field}'"
    }
    String value
    withEnv(["ARCHIVE=${archive}", "FIELD=${field}"]) {
        value = sh(returnStdout: true,
                   script: 'bash "$CI_LIB_DIR/sdist-meta.sh" "$ARCHIVE" "$FIELD"').trim()
    }
    return value
}

// Laedt eine sdist in das Nexus-PyPI-HOSTED-Repo.
//   publish(archive: 'dist/x-1.0.tar.gz', nexusUrl: 'https://nexus...',
//           hostedRepo: 'pypi-hosted', credentialsId: 'nexus-pypi-deploy')
// Das Secret wird nur fuer diesen einen sh-Schritt gebunden und von Jenkins im
// Log maskiert; das Skript liest es aus der Umgebung, nicht aus argv.
void publish(Map args) {
    requireInstalled()
    for (String k : ['archive', 'nexusUrl']) {
        if (!args[k]) {
            error "pyMonorepo.publish: ${k} fehlt"
        }
    }
    withEnv(["NEXUS_URL=${args.nexusUrl}",
             "NEXUS_PYPI_HOSTED=${args.hostedRepo ?: 'pypi-hosted'}",
             "ARCHIVE=${args.archive}"]) {
        withCredentials([usernamePassword(
                credentialsId: args.credentialsId ?: 'nexus-pypi-deploy',
                usernameVariable: 'NEXUS_USER',
                passwordVariable: 'NEXUS_PASS')]) {
            sh 'bash "$CI_LIB_DIR/publish-pypi.sh" "$ARCHIVE"'
        }
    }
}

// Entfernt dist/ und das Skriptverzeichnis. Idempotent; laeuft auch, wenn
// install() nie aufgerufen wurde.
void cleanup() {
    sh 'rm -rf dist'
    if (env.CI_LIB_DIR) {
        sh 'rm -rf "$CI_LIB_DIR"'
    }
    // Leeren, nicht nur den Ordner loeschen: ein spaeterer Einzel-Step in
    // derselben Pipeline soll an requireInstalled() mit einer klaren
    // Fehlermeldung scheitern, nicht erst in der Shell an einem fehlenden
    // Verzeichnis (M-6).
    env.CI_LIB_DIR = ''
}

// ---------------------------------------------------------------------------
// Private Helfer
// ---------------------------------------------------------------------------

// Das Ziel liegt im Checkout, faellt dort aber nicht auf: der fuehrende Punkt
// haelt es aus dem '*/'-Glob von changed-packages.sh heraus. Als Paket wuerde
// es ohnehin nie zaehlen - dafuer fehlen pyproject.toml/setup.py/setup.cfg.
// Eine Methode statt eines statischen Felds: statische Felder in vars/ werden
// zwischen Builds geteilt und machen mit CPS/Serialisierung Aerger.
private String libDir() { return '.ci-lib' }

private void requireInstalled() {
    if (!env.CI_LIB_DIR) {
        error 'pyMonorepo: install() wurde nicht aufgerufen - env.CI_LIB_DIR fehlt'
    }
}

// params existiert nur, wenn die Pipeline Parameter definiert (und in manchen
// Kontexten gar nicht) - und ist in Jenkins-CPS eine GlobalVariable, kein
// Eintrag im Binding: binding.hasVariable('params') sieht sie deshalb NICHT
// (liefert immer false), erst der Property-Zugriff (ueber
// CpsScript.getProperty()s MissingPropertyException-Fallback) loest sie auf.
// Deshalb zwei Stufen: zuerst binding.hasVariable() pruefen (deckt ab, falls
// 'params' dort doch einmal steht), sonst per try/catch den Property-Zugriff
// versuchen - schlaegt der fehl (keine Pipeline-Parameter definiert), gibt es
// den Default. Ohne diese Absicherung wuerde ein eingebetteter Aufruf in
// einer Pipeline ohne parameters{} mit MissingPropertyException sterben.
private boolean paramOr(String name, boolean dflt) {
    def p = null
    if (binding.hasVariable('params')) {
        p = binding.getVariable('params')
    } else {
        try { p = params } catch (Exception ignored) { return dflt }
    }
    if (!(p instanceof Map) || !p.containsKey(name)) { return dflt }
    return toBool(p[name], dflt)
}

// 'false' as boolean waere true (Groovy-Truthiness: ein nicht-leerer String
// ist wahr) - betrifft jeden Boolean-Parameter, der als String hereinkommt
// (z.B. string(name: 'SKIP_UPLOAD', defaultValue: 'false') in der
// einbettenden Pipeline). Strings werden deshalb geparst, Booleans
// durchgereicht, alles andere faellt auf den Default zurueck (I-1/I-2).
private boolean toBool(Object v, boolean dflt) {
    if (v == null) { return dflt }
    if (v instanceof Boolean) { return (Boolean) v }
    return v.toString().trim().equalsIgnoreCase('true')
}

// Basis fuer den Diff: letzter erfolgreicher Build (Git-Plugin setzt das),
// sonst HEAD~1, sonst leer -> alles bauen.
private String defaultBase() {
    return env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?:
        sh(returnStdout: true, script: 'git rev-parse HEAD~1 2>/dev/null || true').trim()
}
