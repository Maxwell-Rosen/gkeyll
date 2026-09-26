// Run from the repository root with: groovy ci/test-jenkins.groovy
// These stubs check helper behavior; they do not emulate the Jenkins CPS runtime.
def workflows = args ? args.toList() : ['personal', 'stellar_cpu', 'perlmutter_gpu'].collect {
    "ci/jenkins/jenkinsfile.${it}"
}
workflows.each { name ->
    def source = new File(name).text
    new GroovyClassLoader().parseClass(source)
    def helpers = source.substring(source.indexOf('def ciStage('), source.indexOf('def writeCiFailureSummary('))
    def env = [:]
    def build = [currentResult: 'SUCCESS', description: 'CI']
    def calls = []
    def temp = java.nio.file.Files.createTempDirectory('gkeyll-jenkins-test-').toFile()
    try {
        def binding = new Binding([
            env: env, currentBuild: build,
            stage: { String label, Closure body -> calls << label; body() },
            catchError: { Map options, Closure body ->
                assert options == [buildResult: 'FAILURE', stageResult: 'FAILURE', catchInterruptions: false]
                try { body() } catch (InterruptedException err) { throw err }
                catch (Exception err) { build.currentResult = options.buildResult }
            },
            sh: { String script ->
                def process = new ProcessBuilder('bash', '-c', script).directory(temp).redirectErrorStream(true).start()
                def output = process.inputStream.text
                assert process.waitFor() == 0 : output
            },
            readFile: { String path -> new File(temp, path).text }
        ])
        def script = new GroovyShell(binding).parse(helpers)
        script.ciStage('first') { throw new RuntimeException('build failed') }
        script.ciStage('second') { calls << 'ran second' }
        script.ciStage('third') { throw new RuntimeException('test failed') }
        assert calls == ['first', 'second', 'ran second', 'third']
        assert build.currentResult == 'FAILURE'
        assert env.CI_FAILED_STAGES.contains('first:') && env.CI_FAILED_STAGES.contains('third:')
        try {
            script.ciStage('cancelled') { throw new InterruptedException('cancel') }
            assert false : 'Cancellation was swallowed'
        } catch (InterruptedException expected) { }
        new File(temp, 'candidate.log').text = 'a.c:3: warning: unused\na.cu(4): warning #20012-D: attribute\na.c:5: \u001b[35mwarning:\u001b[0m conversion\n'
        script.writeCiWarningSummary()
        assert new File(temp, 'ci-warning-summary.txt').text.contains('Compiler warnings: 3')
        assert build.description.contains('Compiler warnings: 3')
        new File(temp, 'candidate.log').delete()
        script.writeCiWarningSummary()
        assert new File(temp, 'ci-warning-summary.txt').text.contains('Compiler warnings: 0')
        println "PASS ${name}: syntax, continued failures, cancellation, warning summaries"
    } finally { temp.deleteDir() }
}
