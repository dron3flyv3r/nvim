# Notebook runtime

The notebook workflow keeps Python source in percent format (`# %%` cells) so
basedpyright, ruff, refactoring, and Git operate on ordinary text. jupytext owns
the `.ipynb` conversion, Molten owns the live kernel and outputs, and image.nvim
renders graphical results.

The editor's Python host lives in a dedicated `molten-venv`; project packages
stay in each project's own environment. `:NotebookBootstrap` creates the host
environment, while `:NotebookKernel` registers a project interpreter as a
Jupyter kernel.

Cell parsing and navigation are independent of the runtime and live in
`lua/user/integrations/notebook/cells.lua`. Kernel selection, environment
bootstrap, output persistence, and compatibility wiring remain behind the
public `user.integrations.notebook` module.

Saved outputs need an explicit round trip: jupytext writes code and Molten then
merges outputs into the resulting notebook. Markdown cells must not be sent to
Molten as code cells because that breaks output matching during export.

First run:

1. Run `:NotebookBootstrap` and restart Neovim.
2. Add `ipykernel` to the project environment.
3. Run `:NotebookKernel` once for that project.
4. Use `<Leader>ra` to choose the current-cell action.
