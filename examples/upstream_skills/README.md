# Reuse upstream skills

This example fetches an explicitly chosen Git commit and loads selected upstream
`SKILL.md` files into an ordinary Alto prompt. It keeps the **whole repository**,
including scripts, references, assets, and licenses. Alto does not own a skill
catalogue, register these skills globally, or update them automatically.

The helper lives only in this example. No runtime or provider changes are needed.
It requires Git and the existing Alto/Contrib packages. Fetching and loading never
install dependencies or execute the fetched scripts.

## Fetch and select

From `packages/alto_contrib`, run `iex -S mix`, then explicitly choose a source,
commit, destination, and skill directory:

```elixir
Code.require_file("../../examples/upstream_skills/lib/upstream_skills.ex")
workspace = Path.expand("~/my-project")
sources = Path.join(workspace, ".upstream-skills")
File.mkdir_p!(sources)

# Verified upstream revision; choose and review a newer full commit when needed.
commit = "49f948faa9258a0c61caceaf225e179651397431"
{:ok, checkout} = UpstreamSkills.fetch(
  "https://github.com/openai/skills.git",
  commit,
  Path.join(sources, "openai")
)
{:ok, skills} = UpstreamSkills.load(checkout, commit, ["skills/.curated/jupyter-notebook"])
```

The [OpenAI notebook skill at this revision](https://github.com/openai/skills/tree/49f948faa9258a0c61caceaf225e179651397431/skills/.curated/jupyter-notebook)
includes its helper script, templates and references. Fetching only `SKILL.md`
would lose those dependencies.

For another source, use the same calls with
`https://github.com/badlogic/pi-skills.git`, commit
`90bb51cae36515a648515b633a81c0c6efc8c74d`, a fresh destination such as
`Path.join(sources, "pi")`, and `["brave-search"]`.
The [Pi repository](https://github.com/badlogic/pi-skills/tree/90bb51cae36515a648515b633a81c0c6efc8c74d)
documents its `{baseDir}` convention; `UpstreamSkills.prompt/1` expands that
placeholder to the selected skill directory. These are usage examples, not a
recommended or maintained catalogue.

## Compose the existing tools and prompt

```elixir
prompt = fn context ->
  Alto.Prompt.render([
    Alto.Contrib.Prompts.Coding.build(context),
    UpstreamSkills.prompt(skills)
  ])
end

# `provider` is your existing trusted provider configuration.
Alto.Contrib.run("Explain the selected skill and its supporting files.",
  cwd: workspace,
  provider: provider,
  prompt: prompt,
  tools: [Alto.Contrib.Tools.ReadFile, Alto.Contrib.Tools.ListFiles],
  approval: {:deny, :policy_denied}
)
```

The skill directory is named in the prompt, so ordinary workspace tools can read
supporting files relative to it. For actual script execution or editing, the
host must explicitly supply the corresponding tools and approval policy. Skill
instructions do not add capabilities. Upstream instructions may assume another
agent's tool names, environment variables or installed packages; adapt the host
configuration for the selected workflow. This example does not interpret YAML
frontmatter or implement automatic skill selection.

`load/3` checks the expected commit and a clean checkout, including supporting
files, ignored files, and untracked additions. It rejects symlinks, submodules,
sparse/assume-unchanged index entries and unsafe selected paths. Each call selects
1–8 directories, with at most 32,000 UTF-8 bytes per `SKILL.md`; oversized skills
fail instead of being silently truncated. Keep dependency installations outside
this checkout so they do not invalidate the pin. The check is a snapshot: keep
the checkout unchanged during the run.

Fetch uses normal Git transport behavior against explicitly trusted sources; it
has no repository-size or network-duration limit. The checkout can be larger
than the selected skill. Its parent directory must exist. Existing destinations
are refused, and a failed fetch leaves its partial directory for inspection; use
a fresh destination after resolving the failure. Git errors return only the
stage and exit status, without a potentially credential-bearing URL. Global Git
configuration is ignored and Git hooks, filesystem monitors and submodule
recursion are disabled by the helper.

## Offline verification

```sh
cd packages/alto_contrib
mix test test/alto/examples_upstream_skills_test.exs
```

Tests use local Git fixtures and the existing `ReadFile` tool. They require no
network, credentials, provider calls, or upstream dependency installation.
