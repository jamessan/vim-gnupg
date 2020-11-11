" Name:    gnupg.vim
" Last Change: 2020 Nov 11
" Maintainer:  James McCoy <jamessan@jamessan.com>
" Original Author:  Markus Braun <markus.braun@krawel.de>
" Summary: Vim plugin for transparent editing of gpg encrypted files.
" License: This program is free software; you can redistribute it and/or
"          modify it under the terms of the GNU General Public License
"          as published by the Free Software Foundation; either version
"          2 of the License, or (at your option) any later version.
"          See https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
"
" Section: Plugin header {{{1

" guard against multiple loads {{{2
if (exists("g:loaded_gnupg") || &cp || exists("#GnuPG"))
  finish
endif
let g:loaded_gnupg = '2.7.2-dev'

" check for correct vim version {{{2
if (v:version < 702)
  echohl ErrorMsg | echo 'plugin gnupg.vim requires Vim version >= 7.2' | echohl None
  finish
endif

" Section: Autocmd setup {{{1

if (!exists("g:GPGFilePattern"))
  let g:GPGFilePattern = '*.{gpg,asc,pgp}'
endif

augroup GnuPG
  autocmd!

  " do the decryption
  exe "autocmd BufReadCmd " . g:GPGFilePattern .  " call gnupg#init(1) |" .
                                                \ " call gnupg#decrypt(1)"
  exe "autocmd FileReadCmd " . g:GPGFilePattern . " call gnupg#init(0) |" .
                                                \ " call gnupg#decrypt(0)"

  " convert all text to encrypted text before writing
  " We check for GPGCorrespondingTo to avoid triggering on writes in GPG Options/Recipient windows
  exe "autocmd BufWriteCmd,FileWriteCmd " . g:GPGFilePattern . " if !exists('b:GPGCorrespondingTo') |" .
                                                             \ " call gnupg#init(0) |" .
                                                             \ " call gnupg#encrypt() |" .
                                                             \ " endif"
augroup END

" Section: Highlight setup {{{1

highlight default link GPGWarning WarningMsg
highlight default link GPGError ErrorMsg
highlight default link GPGHighlightUnknownRecipient ErrorMsg

" Section: Commands {{{1

command! GPGViewRecipients call gnupg#view_recipients()
command! GPGEditRecipients call gnupg#edit_recipients()
command! GPGViewOptions call gnupg#view_options()
command! GPGEditOptions call gnupg#edit_options()

" Section: Menu {{{1

if (has("menu"))
  amenu <silent> Plugin.GnuPG.View\ Recipients :GPGViewRecipients<CR>
  amenu <silent> Plugin.GnuPG.Edit\ Recipients :GPGEditRecipients<CR>
  amenu <silent> Plugin.GnuPG.View\ Options :GPGViewOptions<CR>
  amenu <silent> Plugin.GnuPG.Edit\ Options :GPGEditOptions<CR>
endif

" vim600: set foldmethod=marker foldlevel=0 :
