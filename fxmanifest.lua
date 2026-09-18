fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qb-codedoors'
author 'qb-codedoors'
description 'Aim-based 4-digit code door locks (doors, double doors, gates, garage doors) for QBCore'
version '2.0.1'

shared_scripts {
    'config.lua',
}

client_scripts {
    'client/main.lua',
    'client/creator.lua',
    'client/nui.lua',
}

server_scripts {
    'server/main.lua',
    'server/admin.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
}

dependencies {
    'qb-core',
}
