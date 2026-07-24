# Contributing to ratchet

Thank you for considering contributing to ratchet! This is a clean, public, open-source project with no internal or proprietary code.

## Before you contribute

1. **Run selftest**: `bin/ratchet --selftest` (all 19 tests must pass)
2. **Keep task-agnostic**: Zero project knowledge in `lib/`, `bin/`, `templates/`
3. **Repo contract is the boundary**: The 4 files (`.ratchet.conf`, `AGENTS.md`, `PLAN.md`, `LEARNINGS.md`) are the ONLY place project specifics live

## Development setup

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/ratchet.git
cd ratchet

# Test bash core
bin/ratchet --selftest

# Try it on the demo
bin/ratchet doctor examples/demo-repo
```

## Project structure

```
ratchet/
├── bin/ratchet              # entrypoint (bash)
├── lib/*.sh                 # bash modules (sourced by bin/ratchet)
│   ├── common.sh            # output, defaults, shared helpers
│   ├── contract.sh          # parse .ratchet.conf
│   ├── tracker.sh           # PLAN.md grammar parser
│   ├── model-fallback.sh    # first-available + bench/cooldown
│   ├── run-turn.sh          # one agent -p call + watchdog
│   ├── classify.sh          # turn classification (token/error detection)
│   ├── commit-gate.sh       # re-verify + stage + commit
│   ├── session-sanitize.sh  # strip thinking blocks (cross-provider)
│   ├── observability.sh     # heartbeats, excerpts, watch
│   └── commands.sh          # init/new/doctor
├── templates/               # onboarding files
├── test/selftest.sh         # no-API verification suite
├── examples/demo-repo/      # tutorial/demo project
└── docs/                    # deep-dive documentation (future)
```

## Testing

### Selftest (no API calls)

```bash
bin/ratchet --selftest
```

This verifies:
- Turn classification logic (token/error detection)
- Session sanitizer
- Agnosticism (zero project knowledge grep-check)
- End-to-end with a fake agent

### Manual testing

```bash
# Test onboarding
mkdir /tmp/test-repo && cd /tmp/test-repo && git init
~/path/to/ratchet/bin/ratchet init .
~/path/to/ratchet/bin/ratchet doctor .

# Test one turn (with a real agent)
~/path/to/ratchet/bin/ratchet once . --models your/model
```

## Code style

### Bash
- Bash 3.2+ compatible (no associative arrays, no `timeout` binary)
- Use `set -o pipefail`
- Quote all variables: `"$VAR"` not `$VAR`
- Functions: `snake_case`
- Globals: `UPPER_CASE`
- Local vars: `lower_case`

### Output
- `emit "msg"` - terminal + log
- `term_only "msg"` - terminal only (heartbeats)
- `die "error"` - fatal error
- `vlog "msg"` - verbose only

### Comments
- Document WHY, not WHAT (the code shows what)
- Mark TODOs: `# TODO: description`
- Mark known limitations: `# LIMITATION: description`

## The agnosticism invariant

The core engine must never contain project-specific knowledge. Run this check:

```bash
# Should find ZERO matches in lib/, bin/, templates/
grep -riE 'npm|pytest|cargo|mix|rspec|go test' lib/ bin/ templates/
```

All project specifics live in the target repo's contract files (`.ratchet.conf`, `AGENTS.md`, `PLAN.md`).

## Contribution workflow

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes
4. Run selftest: `bin/ratchet --selftest`
5. Commit with descriptive messages
6. Push and open a PR

## What we're looking for

- Bug fixes
- Documentation improvements
- New provider integrations (model fallback)
- Testing improvements
- Performance optimizations
- TypeScript wrapper (see ROADMAP)
- Example repos / tutorials

## What to avoid

- Breaking the agnosticism invariant (project knowledge in core)
- Adding dependencies (keep bash core dependency-free)
- Breaking bash 3.2 compatibility
- Over-engineering (YAGNI - solve real problems, not hypothetical ones)

## Questions?

Open an issue and we'll discuss!

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
