# Examples

- Create a directory for each example.
- Create a `_header.md` file in each directory to describe the example.
- Required baseline scenarios are named `default` or `defaults`; if both exist, both run. The `waf-aligned` scenario is also required when present. The workflow warns if neither baseline name exists.
- Integration tests run on every PR. Add `PR: Run Required E2E Tests` to run required examples, or `PR: Run All E2E Tests` to include optional examples. Apply a label only when the PR is ready for deployments to avoid unnecessary cloud cost and runtime.
- Run `make fmt && make docs` from the repo root to generate the required documentation.
- If you want an example to be ignored by the end to end pipeline add a `.e2eignore` file to the example directory.

> **Note:** Examples must be deployable and idempotent. Ensure that no input variables are required to run the example and that random values are used to ensure unique resource names. E.g. use the [naming module](https://registry.terraform.io/modules/Azure/naming/azurerm/latest) to generate a unique name for a resource.
