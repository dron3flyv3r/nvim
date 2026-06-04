vim.diagnostic.config({
    virtual_text = {
        prefix = "●",
        spacing = 4,
        source = "if_many",
    },
    signs = true,
    underline = true,
    update_in_insert = true,
    severity_sort = true,
    float = {
        border = "rounded",
        source = "if_many",
    },
})

local signs = {
    Error = " ",
    Warn = " ",
    Hint = "󰌵 ",
    Info = " ",
}

for type, icon in pairs(signs) do
    local hl = "DiagnosticSign" .. type
    vim.fn.sign_define(hl, {
        text = icon,
        texthl = hl,
        numhl = "",
    })
end