# Repository instructions

These instructions apply to all files in this repository.

## Communication

- Use clear technical English in all documentation and communication, including comments, commit messages, pull request text, progress reports, and final responses.
  - Use short sentences, familiar words, and active voice.
  - Use consistent terms and direct instructions.
  - State the main point first and remove unnecessary text.
  - Make requirements specific and verifiable.
  - Keep standard software terms and explain unfamiliar terms when needed.
  - Keep proper nouns, technical names, identifiers, commands, and paths exact.
  - Put dependent rules in indented sub-items.
- Report verified results separately from plans, assumptions, and checks that you did not run.

## Documentation

- Read `README.md` and the relevant sections of `PLAN.md` before making changes.
- Keep the product overview in `README.md` and implementation steps, open decisions, and acceptance checks in `PLAN.md`.
- Distinguish proposed features from implemented and tested behavior.
- Do not publish installation steps, build commands, supported versions, or release claims without evidence.
- Update affected documentation when a change alters documented behavior or requirements.

## Code style

- Use Swift for the iOS app, macOS companion, and shared app code; do not add a TypeScript backend.
- Keep platform-specific process and networking code outside the shared package.
- Use the simplest solution that meets the current requirement; do not add features or settings for possible future needs.

## Boundaries

- Keep changes within the requested scope and preserve unrelated work.
- Ask before destructive actions, external writes other than the Git operations authorized below, or major scope changes.
- Treat `PLAN.md` as a proposed design, not as evidence that a feature works.
- Do not mark a plan item complete until its stated checks pass.

## Security

- Keep provider credentials on the Mac and exclude secrets, pairing data, prompt text, and tool output from routine diagnostic logs.
- Do not weaken certificate checks or authentication to make a connection work.
- Do not describe registered project folders as a security sandbox for Pi tools.

## Testing

- Use checks that match the changed files and report their results.
- Run `git diff --check` after edits.
- Verify referenced local paths and keep documentation consistent with the repository.
- Verify build and test commands from project configuration before using or documenting them; no app build or test configuration exists yet.

## Git and commits

- During the current rapid-development phase, you may commit and push verified, in-scope changes directly to `main` without separate approval; branches and pull requests are optional unless the user explicitly requests them.
