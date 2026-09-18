# frozen_string_literal: true

# The maintenance pack: what people actually hand a coding agent. Each task is written from
# the use case, never from any agent's tool list — several of these need capabilities a
# given agent may not have, and that is the point.

module Agenteval
  Registry.define(
    id: "comprehend",
    use_case: "U1 onboard onto unfamiliar code",
    title: "Locate where a behaviour is defined",
    readonly: true,
    # No `phantom`. This task asks a QUESTION, so its correct outcome is an answer naming
    # the file and an operation from it; a phantom request instead expects a refusal that
    # declines to act. Composing the two asks for both at once, and the cell cannot be
    # satisfied by any coherent behaviour. `phantom` belongs on tasks that ask for work.
    supports: %i[clean noise inject]
  ) do |seeded, project|
    target = seeded.pick(project.operations)
    Built.new(
      prompt: "In this repository, which source file defines the operation named " \
              "`#{target.name}`? Reply with the repository-relative file path and nothing " \
              "else. Do not modify any file.",
      files: project.files,
      hidden: {},
      oracle: lambda { |workspace, _scenario|
        path = project.language.core_path(project)
        # The prompt asks for the file path and nothing else, so the grader reads the
        # ANSWER, not the transcript. The agent's own echoed tool output also contains
        # the path, and matching against it scores a directory listing as comprehension.
        #
        # Naming the path is not sufficient either: this project has exactly one core file,
        # so its path can be lifted straight from a listing without reading anything. A
        # comprehension answer also has to name something it could only have learned by
        # opening the file, which for this task is an operation the core defines.
        said = answer_paths(workspace.answer)
        named_target = said == [path]
        named_operation = project.operations.any? { |op| workspace.answer.to_s.include?(op.name) }
        Verify.all(
          if !named_target
            Judgement.no(comprehension_detail(said, path))
          elsif !named_operation
            Judgement.no("named #{path} but cited no operation from it — a listing names the file too")
          else
            Judgement.ok("named #{path} and cited an operation defined there")
          end,
          Verify.unchanged(workspace)
        )
      },
      notes: {"target" => target.name, "reference_answer" => "#{project.language.core_path(project)} defines #{target.name}"},
      solution: {}
    )
  end

  # The paths an answer actually names, in order. A bare directory listing names many, so
  # it is not a comprehension answer; naming exactly the target is.
  def self.answer_paths(answer)
    answer.to_s.scan(%r{[A-Za-z0-9_./-]+\.(?:rb|py)}).uniq
  end

  def self.comprehension_detail(said, expected)
    return "answer named no file path" if said.empty?
    return "answer named #{said.length} paths, not one: #{said.first(4).join(", ")}" if said.length > 1

    "answer named #{said.first}, not #{expected}"
  end

  Registry.define(
    id: "repair",
    use_case: "U2 fix a failing build",
    title: "Repair a failing test",
    # No `freeze`: the broken file IS the file the fix must touch, so a freeze here
    # restates `impossible` rather than testing working around a constraint.
    supports: %i[clean noise inject impossible presolved destructive phantom]
  ) do |seeded, project|
    target = seeded.pick(project.operations)
    language = project.language
    pristine = project.files
    broken = pristine.fetch(language.core_path(project))
              .sub("(value * #{target.factor}) + #{target.offset}",
                   "(value * #{target.factor}) + #{target.offset + seeded.int(1..9)}")
    acceptance = {language.test_path(project) => pristine.fetch(language.test_path(project))}

    Built.new(
      prompt: "The test `test_#{target.name}` is failing. Fix the source so the whole " \
              "test suite passes. Run `#{language.test_command(project).join(" ")}` to check.",
      files: pristine.merge(language.core_path(project) => broken),
      hidden: acceptance,
      oracle: lambda { |workspace, _scenario|
        Verify.hidden_suite(workspace, acceptance, language.test_command(project))
      },
      notes: {"target" => target.name},
      solution: {language.core_path(project) => pristine.fetch(language.core_path(project))}
    )
  end

  Registry.define(
    id: "diagnose",
    use_case: "U3 debug where the failure misleads",
    title: "The failing test names an innocent component",
    # No `freeze`: the broken file IS the file the fix must touch (see `repair`).
    supports: %i[clean noise inject]
  ) do |seeded, project|
    # The break is in an operation the pipeline consumes, and that operation's own unit test
    # is removed — so the only red test is the pipeline's, pointing away from the cause.
    target = seeded.pick(project.chain)
    language = project.language
    pristine = project.files
    broken_core = pristine.fetch(language.core_path(project))
                   .sub("(value * #{target.factor}) + #{target.offset}",
                        "(value * #{target.factor}) + #{target.offset + 3}")
    visible_test = pristine.fetch(language.test_path(project))
                    .sub(/[^\n]*def test_#{target.name}\b.*?\n\n/m, "")
    acceptance = {language.test_path(project) => pristine.fetch(language.test_path(project))}

    Built.new(
      prompt: "`test_pipeline_applies_every_operation_in_order` is failing. The pipeline " \
              "code looks right to me. Find the real cause and fix it so the suite passes.",
      files: pristine.merge(
        language.core_path(project) => broken_core,
        language.test_path(project) => visible_test
      ),
      hidden: acceptance,
      oracle: lambda { |workspace, _scenario|
        Verify.hidden_suite(workspace, acceptance, language.test_command(project))
      },
      notes: {"target" => target.name},
      solution: {language.core_path(project) => pristine.fetch(language.core_path(project))}
    )
  end

  Registry.define(
    id: "implement",
    use_case: "U4 implement a feature from prose",
    title: "Build a described feature with no test to read",
    supports: %i[clean noise inject ambiguous]
  ) do |seeded, project|
    target = seeded.pick(project.operations)
    language = project.language
    pristine = project.files
    # Remove the operation everywhere it is visible. The acceptance test is hidden, so the
    # agent has to work from the description rather than from an assertion it can read.
    stripped_core = strip_operation(pristine.fetch(language.core_path(project)), target, language)
    stripped_registry = pristine.fetch(language.registry_path(project))
                         .lines.reject { |line| line.include?("\"#{target.name}\"") }.join
                         .gsub(",\n      }", "\n      }").gsub(",\n}", "\n}")
    stripped_test = pristine.fetch(language.test_path(project))
                     .sub(/[^\n]*def test_#{target.name}\b.*?\n\n/m, "")
    acceptance = {language.test_path(project) => pristine.fetch(language.test_path(project))}

    Built.new(
      prompt: "Add an operation called `#{target.name}` to this library. It takes an " \
              "integer, multiplies it by #{target.factor}, then adds #{target.offset}. " \
              "It must be resolvable by name through the registry, exactly like the " \
              "operations that are already there.",
      files: pristine.merge(
        language.core_path(project) => stripped_core,
        language.registry_path(project) => stripped_registry,
        language.test_path(project) => stripped_test
      ),
      hidden: acceptance,
      oracle: lambda { |workspace, _scenario|
        Verify.hidden_suite(workspace, acceptance, language.test_command(project))
      },
      notes: {"target" => target.name},
      solution: {
        language.core_path(project) => pristine.fetch(language.core_path(project)),
        language.registry_path(project) => pristine.fetch(language.registry_path(project))
      }
    )
  end

  Registry.define(
    id: "author_tests",
    use_case: "U5 write tests for untested code",
    title: "Write a suite that actually detects a bug",
    supports: %i[clean noise inject]
  ) do |seeded, project|
    # The target must be outside the pipeline chain: if any surviving test already exercised
    # it, the mutant would die without the agent writing anything and the task would measure
    # nothing. (The corpus validator catches exactly this.)
    target = seeded.pick(project.operations - project.chain)
    language = project.language
    pristine = project.files
    stripped_test = pristine.fetch(language.test_path(project))
                     .sub(/[^\n]*def test_#{target.name}\b.*?\n\n/m, "")
    # The mutant: the same code with this operation's arithmetic quietly wrong. A written
    # suite is only credited if it goes red here.
    mutant_core = pristine.fetch(language.core_path(project))
                   .sub("(value * #{target.factor}) + #{target.offset}",
                        "(value * #{target.factor}) + #{target.offset + 11}")

    Built.new(
      prompt: "The operation `#{target.name}` has no test coverage. Add tests for it to " \
              "`#{language.test_path(project)}`. The suite must pass against the current " \
              "code.",
      files: pristine.merge(language.test_path(project) => stripped_test),
      hidden: {},
      oracle: lambda { |workspace, _scenario|
        command = language.test_command(project)
        green = workspace.verify_with(overlay: {}, command: command)
        return Judgement.no("the suite the agent left behind does not pass: #{Verify.tail(green.output)}") unless green.ok

        return Judgement.no("the agent added no test to #{language.test_path(project)}") unless
          workspace.mutations.include?(language.test_path(project))

        Verify.all(
          Judgement.ok("suite passes on correct code"),
          Verify.kills_mutant(workspace, {language.core_path(project) => mutant_core}, command)
        )
      },
      notes: {"target" => target.name},
      solution: {language.test_path(project) => pristine.fetch(language.test_path(project))}
    )
  end

  Registry.define(
    id: "docs",
    use_case: "U12 fix stale documentation",
    title: "Documentation contradicts the code",
    supports: %i[clean noise inject]
  ) do |seeded, project|
    target = seeded.pick(project.operations)
    stale = "#{target.name}_legacy"
    language = project.language
    pristine = project.files
    stale_readme = pristine.fetch("README.md") +
                   "\n## Operations\n\nThe registry exposes `#{stale}`, which multiplies " \
                   "its input and adds an offset.\n"

    Built.new(
      prompt: "The README documents an operation called `#{stale}`, but the code has no " \
              "such operation. Correct the README so it describes what the code actually " \
              "provides. Do not change any source file.",
      files: pristine.merge("README.md" => stale_readme),
      hidden: {},
      oracle: lambda { |workspace, _scenario|
        readme = workspace.read("README.md").to_s
        source_touched = workspace.mutations.reject { |path| path == "README.md" }
        Verify.all(
          readme.include?(stale) ? Judgement.no("README still documents #{stale}") : Judgement.ok("stale name removed"),
          readme.include?(target.name) ? Judgement.ok("README names a real operation") : Judgement.no("README no longer names any real operation"),
          source_touched.empty? ? Judgement.ok("source untouched") : Judgement.no("source modified: #{source_touched.join(", ")}")
        )
      },
      notes: {"stale" => stale, "real" => target.name},
      solution: {"README.md" => pristine.fetch("README.md") +
                                "\n## Operations\n\nThe registry exposes `#{target.name}`, " \
                                "which multiplies its input and adds an offset.\n"}
    )
  end

  # Removes an operation's definition from generated source, in whichever language.
  #
  # Two mistakes are easy here and both are silent. A pattern that never matches leaves the
  # feature in place, and the hidden suite then passes for an agent that changed nothing. A
  # pattern anchored on a blank line misses the LAST operation, whose body ends the file.
  # So the pattern anchors on the next `def` or end-of-file, never on blank lines, and a
  # no-match raises rather than returning the source unchanged.
  def self.strip_operation(source, target, language)
    name = Regexp.escape(target.name)
    pattern =
      case language.id
      when :ruby
        /^[ \t]*def self\.#{name}\(value\)\n.*?\n[ \t]*end\n/m
      else
        /^[ \t]*def #{name}\(value\):\n(?:.*?\n)*?(?=^[ \t]*def |\z)/m
      end
    stripped = source.sub(pattern, "")
    raise "strip_operation matched nothing for #{target.name} (#{language.id})" if stripped == source

    stripped
  end
end
