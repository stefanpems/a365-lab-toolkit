# Workspace Language Policy

- The English-only requirement applies only to user-requested creation or modification of this workspace's
  procedures and their implementation. Write the related source code, scripts, agent definitions, skills,
  instructions, prompts, documentation, notes, logs, configuration files, comments, test data, and
  commit-related text prepared in files in English.
- The requirement does not apply to files or folders produced by agents' runtime procedures when users
  interact with those procedures to create or configure resources. Preserve the language and names requested
  by the user. For example, Demo Builder may generate a demo environment in Spanish, and Lab Builder may use
  a French name supplied by the user for an agent.
- All files and folders under the workspace-root `generated` directory, including their names and contents,
  are exempt from the English-only requirement, regardless of how they are created or modified.
- Demo Builder must always offer exactly English (EN), Italian (IT), Spanish (ES), French (FR), and German (DE).
  All five are supported equally for runtime-generated environments, resource names, localized content, and
  files. Never apply the English-only maintenance requirement to hide a language, force English output,
  require a language exception or approval, or block an IT, ES, FR, or DE build.
- Do not translate unrelated existing content unless the task requires it.
- When writing content subject to the English-only requirement, prefer the English meaning and usage of
  a word or phrase that is valid in multiple languages.
- Prefer replying in the requester's language in chat, including questions, structured input controls,
  progress updates, warnings, errors, and final responses. Chat language does not change the scope or
  exceptions of this policy.