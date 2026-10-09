<!--# cspell: ignore SSOT CMDB -->
# AGENTS.md

Ensure that all practices and instructions described by
<https://raw.githubusercontent.com/ansible/ansible-creator/refs/heads/main/docs/agents.md>
are followed.

## Documentation ownership

Operational runbooks and durable architecture decisions belong in
`/workspace/igou-docs`. Keep implementation plans in the conversation; if a
persistent record is needed, write a concise decision note in that vault.
Do not create `docs/superpowers/` or repository-local agent execution plans.
Keep public API/collection documentation, READMEs, and agent instructions
beside the code. Update the relevant vault note when behavior changes.

Lab-specific guidance: [Armbian Collection Design Decisions](https://github.com/igou-io/igou-docs/blob/main/reference/Armbian%20Collection%20Design%20Decisions.md).
