local Terminal = require("toggleterm.terminal").Terminal

local M = {}

local function find_justfile_dir()
    local file = vim.fn.findfile("justfile", ".;")

    if file == "" then
        file = vim.fn.findfile("Justfile", ".;")
    end

    if file == "" then
        return vim.fn.getcwd()
    end

    return vim.fn.fnamemodify(file, ":p:h")
end

local function run_just(task)
    local cwd = find_justfile_dir()

    local term = Terminal:new({
        cmd = "just " .. task,
        dir = cwd,
        direction = "horizontal",
        close_on_exit = false,
        hidden = false,
        start_in_insert = true,
    })

    term:toggle()
end

function M.deploy()
    run_just("deploy")
end

function M.deploy_force()
    run_just("deploy-force")
end

return M