" Name: gnupg.vim
" Version: $Id: gnupg.vim,v 1.26 2003/05/30 09:29:16 mb Exp $
" Author: Markus Braun <markus.braun@krawel.de>
" Summary: Vim plugin for transparent editing of gpg encrypted files.
" TODO enable signing
" TODO GPGOptions for encrypting, signing, auto fetch ..
" Section: Documentation {{{1
" Description:
"   
"   This script implements transparent editing of gpg encrypted files. The
"   filename must have a ".gpg" suffix. When opening such a file the content is
"   decrypted, when opening a new file the script will ask for the recipients of
"   the encrypted file. The file content will be encrypted to all recipients
"   before it is written. The script turns off viminfo and swapfile to increase
"   security.
"
" Installation: 
"
"   Copy the gnupg.vim file to the $HOME/.vim/plugin directory.
"   Refer to ':help add-plugin', ':help add-global-plugin' and ':help
"   runtimepath' for more details about Vim plugins.
"
" Commands:
"
"   :GPGEditRecipients
"     Opens a scratch buffer to change the list of recipients. Recipients that
"     are unknown (not in your public key) are highlighted and have a
"     prepended "!". Closing the buffer with :x or :bd makes the changes permanent.
"
"   :GPGViewRecipients
"     Prints the list of recipients.
"
" Credits:
"   Mathieu Clabaut for inspirations through his vimspell.vim script.
" Section: Plugin header {{{1
if (exists("loaded_gnupg") || &cp || exists("#BufReadPre#*.gpg"))
	finish
endi
let loaded_gnupg = 1

" dettermine if gnupg can use the gpg-agent
if (exists("$GPG_AGENT_INFO"))
	let s:gpgcommand = "gpg --use-agent"
else
	let s:gpgcommand = "gpg"
endif

" Section: Autocmd setup {{{1
augroup GnuPG
	au!

	" First make sure nothing is written to ~/.viminfo while editing
	" an encrypted file.
	autocmd BufNewFile,BufReadPre,FileReadPre      *.gpg set viminfo=
	" We don't want a swap file, as it writes unencrypted data to disk
	autocmd BufNewFile,BufReadPre,FileReadPre      *.gpg set noswapfile
	" Force the user to edit the recipient list if he opens a new file
	autocmd BufNewFile                             *.gpg call s:GPGEditRecipients()
	" Switch to binary mode to read the encrypted file
	autocmd BufReadPre,FileReadPre                 *.gpg set bin
	autocmd BufReadPost,FileReadPost               *.gpg call s:GPGDecrypt()
	" Switch to normal mode for editing
	autocmd BufReadPost,FileReadPost               *.gpg set nobin
	" Call the autocommand for the file minus .gpg$
	autocmd BufReadPost,FileReadPost               *.gpg execute ":doautocmd BufReadPost " . expand("%:r")
	autocmd BufReadPost,FileReadPost               *.gpg execute ":redraw!"

	" Switch to binary mode before encrypt the file
	autocmd BufWritePre,FileWritePre               *.gpg set bin
	" Convert all text to encrypted text before writing
	autocmd BufWritePre,FileWritePre               *.gpg call s:GPGEncrypt()
	" Undo the encryption so we are back in the normal text, directly
	" after the file has been written.
	autocmd BufWritePost,FileWritePost             *.gpg silent u
	" Switch back to normal mode for editing
	autocmd BufWritePost,FileWritePost             *.gpg set nobin
augroup END
" Section: Highlight setup {{{1
highlight default GPGWarning                   term=reverse ctermfg=Yellow guifg=Yellow
highlight default GPGError                     term=reverse ctermfg=Red guifg=Red
highlight default GPGHighlightUnknownRecipient term=reverse ctermfg=Red cterm=underline guifg=Red gui=underline
" Section: Functions {{{1
" Function: s:GPGDecrypt() {{{2
"
" decrypt the buffer and find all recipients of the encrypted file
"
fun s:GPGDecrypt()
	" get the filename of the current buffer
	let filename=escape(expand("%:p"), ' *?\"'."'")
	
	" clear GPGRecipients, GPGUnknownRecipients and GPGOptions
	let b:GPGRecipients=""
	let b:GPGUnknownRecipients=""
	let b:GPGOptions=""

	" find the recipients of the file
	let output=system(s:gpgcommand . " --decrypt --dry-run --batch " . filename)
	let start=match(output, "ID [[:xdigit:]]\\{8}", 0)
	while (start >= 0)
		let start=start+3
		let recipient=strpart(output, start, 8)
		let name=s:GPGNameToID(recipient)
		if (strlen(name) > 0)
			let b:GPGRecipients=b:GPGRecipients . name . ":" 
		else
			let b:GPGUnknownRecipients=b:GPGUnknownRecipients . recipient . ":" 
			echohl GPGWarning
			echo "The recipient " . recipient . " is not in your public keyring!"
			echohl None
		end
		let start=match(output, "ID [[:xdigit:]]\\{8}", start)
	endw

	"echo "GPGRecipients=\"" . b:GPGRecipients . "\""
	
	" Find out if the message is armored
	if (stridx(getline(1), "-----BEGIN PGP MESSAGE-----") >= 0)
		let b:GPGOptions=b:GPGOptions . "armor:"
	endi

	" finally decrypt the buffer content
	" since even with the --quiet option passphrase typos will be reported,
	" we must redirect stderr (using sh temporarily)
	let shsave=&sh
	let &sh='sh'
	exec "'[,']!" . s:gpgcommand . " --quiet --decrypt 2>/dev/null"
	let &sh=shsave
	if (v:shell_error) " message could not be decrypted
		silent u
		echohl GPGError
		let asd=input("Message could not be decrypted! (Press ENTER)")
		echohl None
		bwipeout
		return
	endi
endf

" Function: s:GPGEncrypt() {{{2
"
" encrypts the buffer to all previous recipients
"
fun s:GPGEncrypt()
	let options=""
	let recipients=""
	let field=0

	" built list of options
	if (exists("b:GPGOptions"))
		let field=0
		let option=s:GetField(b:GPGOptions, ":", field)
		while (strlen(option))
			let options=options . " --" . option . " "
			let field=field+1
			let option=s:GetField(b:GPGOptions, ":", field)
		endw
	endi

	" check if there are unknown recipients and warn
	if (exists("b:GPGUnknownRecipients"))
		if (strlen(b:GPGUnknownRecipients) > 0)
			echohl GPGWarning
			echo "There are unknown recipients!!"
			echo "Please use GPGEditRecipients to correct!!"
			echohl None
		endi
	endi

	" built list of recipients
	if (exists("b:GPGRecipients"))
		let field=0
		let gpgid=s:GetField(b:GPGRecipients, ":", field)
		while (strlen(gpgid))
			let recipients=recipients . " -r " . gpgid
			let field=field+1
			let gpgid=s:GetField(b:GPGRecipients, ":", field)
		endw
	else
		echohl GPGWarning
		echo "There are no recipients!!"
		echo "Please use GPGEditRecipients to correct!!"
		echohl None
	endi

	" encrypt the buffer
	let shsave=&sh
	let &sh='sh'
	exec "'[,']!" . s:gpgcommand . " --quiet --no-encrypt-to --encrypt " . options . recipients . " 2>/dev/null"
	let &sh=shsave

	redraw!
endf

" Function: s:GPGViewRecipients() {{{2
"
" echo the recipients
"
fun s:GPGViewRecipients()
	if (exists("b:GPGRecipients"))
		echo 'This file has following recipients (Unknown recipients have a prepended "!"):'
		" echo the recipients
		let field=0
		let name=s:GetField(b:GPGRecipients, ":", field)
		while (strlen(name) > 0)
			let name=s:GPGIDToName(name)
			echo name

			let field=field+1
			let name=s:GetField(b:GPGRecipients, ":", field)
		endw

		" put the unknown recipients in the scratch buffer
		let field=0
		echohl GPGWarning
		let name=s:GetField(b:GPGUnknownRecipients, ":", field)
		while (strlen(name) > 0)
			let name="!" . name
			echo name

			let field=field+1
			let name=s:GetField(b:GPGUnknownRecipients, ":", field)
		endw
		echohl None

		" check if there is any known recipient
		if (strlen(s:GetField(b:GPGRecipients, ":", 0)) == 0)
			echohl GPGError
			echo 'There are no known recipients!'
			echohl None
		endi
	endi
endf

" Function: s:GPGEditRecipients() {{{2
"
" create a scratch buffer with all recipients to add/remove recipients
"
fun s:GPGEditRecipients()
	" only do this if it isn't already a GPGRecipients_* buffer
	if (match(bufname("%"), "GPGRecipients_") != 0 && match(bufname("%"), "\.gpg$") >= 0)

		" save buffer name
		let buffername=bufname("%")
		let editbuffername="GPGRecipients_" . buffername

		" create scratch buffer
		exe 'silent! split ' . editbuffername

		" check if this buffer exists
		if (bufexists(editbuffername))
			" empty the buffer
			silent normal! 1GdG
		endi

		" Mark the buffer as a scratch buffer
		setlocal buftype=nofile
		setlocal noswapfile
		setlocal nowrap
		setlocal nobuflisted
		setlocal nonumber

		" so we know for which other buffer this edit buffer is
		let b:corresponding_to=buffername

		" put some comments to the scratch buffer
		silent put ='GPG: ----------------------------------------------------------------------'
		silent put ='GPG: Please edit the list of recipients, one recipient per line'
		silent put ='GPG: Unknown recipients have a prepended \"!\"'
		silent put ='GPG: Lines beginning with \"GPG:\" are removed automatically'
		silent put ='GPG: Use :x or :bd to close this buffer'
		silent put ='GPG: ----------------------------------------------------------------------'

		" put the recipients in the scratch buffer
		let recipients=getbufvar(b:corresponding_to, "GPGRecipients")
		let field=0

		let name=s:GetField(recipients, ":", field)
		while (strlen(name) > 0)
			let name=s:GPGIDToName(name)
			silent put =name

			let field=field+1
			let name=s:GetField(recipients, ":", field)
		endw

		" put the unknown recipients in the scratch buffer
		let unknownRecipients=getbufvar(b:corresponding_to, "GPGUnknownRecipients")
		let field=0
		let syntaxPattern="\\(nonexistingwordinthisbuffer"

		let name=s:GetField(unknownRecipients, ":", field)
		while (strlen(name) > 0)
			let name="!" . name
			let syntaxPattern=syntaxPattern . "\\|" . name
			silent put =name

			let field=field+1
			let name=s:GetField(unknownRecipients, ":", field)
		endw

		let syntaxPattern=syntaxPattern . "\\)"

		" define highlight
		if (has("syntax") && exists("g:syntax_on"))
			exec('syntax match GPGUnknownRecipient    "' . syntaxPattern . '"')
			highlight clear GPGUnknownRecipient
			highlight link GPGUnknownRecipient  GPGHighlightUnknownRecipient

			syntax match GPGComment "^GPG:.*$"
			highlight clear GPGComment
			highlight link GPGComment Comment
		endi

		" delete the empty first line
		silent normal! 1Gdd

		" jump to the first recipient
		silent normal! 6G

		" add a autocommand to regenerate the recipients after a write
		augroup GPGEditRecipients
		augroup END
		execute 'au GPGEditRecipients BufHidden ' . editbuffername . ' call s:GPGFinishRecipientsBuffer()'

	endi

endf

" Function: s:GPGFinishRecipientsBuffer() {{{2
"
" create a new recipient list from RecipientsBuffer
fun s:GPGFinishRecipientsBuffer()
	" clear GPGRecipients and GPGUnknownRecipients
	let GPGRecipients=""
	let GPGUnknownRecipients=""

	" delete the autocommand
	exe "au! GPGEditRecipients * " . bufname("%")

	let currentline=1
	let recipient=getline(currentline)

	" get the recipients from the scratch buffer
	while (currentline <= line("$"))
		" delete all spaces at beginning and end of the line
		" also delete a '!' at the beginning of the line
		let recipient=substitute(recipient, "^[[:space:]!]*\\(.\\{-}\\)[[:space:]]*$", "\\1", "")
		" delete comment lines
		let recipient=substitute(recipient, "^GPG:.*$", "", "")

		" only do this if the line is not empty
		if (strlen(recipient) > 0)
			let gpgid=s:GPGNameToID(recipient)
			if (strlen(gpgid) > 0)
				let GPGRecipients=GPGRecipients . gpgid . ":" 
			else
				let GPGUnknownRecipients=GPGUnknownRecipients . recipient . ":"
				echohl GPGWarning
				echo "The recipient " . recipient . " is not in your public keyring!"
				echohl None
			end
		endi

		let currentline=currentline+1
		let recipient=getline(currentline)
	endw
	
	" write back the new recipient list to the corresponding buffer and mark it
	" as modified
	call setbufvar(b:corresponding_to, "GPGRecipients", GPGRecipients)
	call setbufvar(b:corresponding_to, "GPGUnknownRecipients", GPGUnknownRecipients)
	call setbufvar(b:corresponding_to, "&mod", 1)
	"echo "GPGRecipients=\"" . getbufvar(b:corresponding_to, "GPGRecipients") . "\""

	" check if there is any known recipient
	if (strlen(s:GetField(GPGRecipients, ":", 0)) == 0)
		echohl GPGError
		echo 'There are no known recipients!'
		echohl None
	endi


endf

" Function: s:GPGNameToID(name) {{{2
"
" find GPG key ID corresponding to a name
" Returns: ID for the given name
fun s:GPGNameToID(name)
	" ask gpg for the id for a name
	let output=system(s:gpgcommand . " --quiet --with-colons --fixed-list-mode --list-keys \"" . a:name . "\"")

	" parse the output of gpg
	let pub_seen=0
	let uid_seen=0
	let line=0
	let counter=0
	let gpgids=""
	let choices="The name \"" . a:name . "\" is ambiguous. Please select the correct key:\n"
	let linecontent=s:GetField(output, "\n", line)
	while (strlen(linecontent))
		 " search for the next uid
		 if (pub_seen == 1)
			if (s:GetField(linecontent, ":", 0) == "uid")
				if (uid_seen == 0)
					let choices=choices . counter . ": " . s:GetField(linecontent, ":", 9) . "\n"
					let counter=counter+1
					let uid_seen=1
				else
					let choices=choices . "   " . s:GetField(linecontent, ":", 9) . "\n"
				endi
			else
				let uid_seen=0
				let pub_seen=0
			endi
		endi

		" search for the next pub
		if (pub_seen == 0)
			if (s:GetField(linecontent, ":", 0) == "pub")
				let gpgids=gpgids . s:GetField(linecontent, ":", 4) . ":"
				let pub_seen=1
			endi
		endi

		let line=line+1
		let linecontent=s:GetField(output, "\n", line)
	endw

	" counter > 1 means we have more than one results
	let answer=0
	if (counter > 1)
		let choices=choices . "Enter number: "
		let answer=input(choices, "0")
		while (answer == "")
			let answer=input("Enter number: ", "0")
		endw
	endi

	return s:GetField(gpgids, ":", answer)
endf

" Function: s:GPGIDToName(identity) {{{2
"
" find name corresponding to a GPG key ID
" Returns: Name for the given ID
fun s:GPGIDToName(identity)
	" TODO is the encryption subkey really unique?

	" ask gpg for the id for a name
	let output=system(s:gpgcommand . " --quiet --with-colons --fixed-list-mode --list-keys " . a:identity )

	" parse the output of gpg
	let pub_seen=0
	let finish=0
	let line=0
	let linecontent=s:GetField(output, "\n", line)
	while (strlen(linecontent) && !finish)
		if (pub_seen == 0) " search for the next pub
			if (s:GetField(linecontent, ":", 0) == "pub")
				let pub_seen=1
			endi
		else " search for the next uid
			if (s:GetField(linecontent, ":", 0) == "uid")
				let pub_seen=0
				let finish=1
				let uid=s:GetField(linecontent, ":", 9)
			endi
		endi

		let line=line+1
		let linecontent=s:GetField(output, "\n", line)
	endw

  return uid
endf

" Function: s:GetField(line, separator, field) {{{2
"
" find field of 'separator' separated string, counting starts with 0
" Returns: content of the field, if field doesn't exist it returns an empty
"          string
fun s:GetField(line, separator, field)
	let counter=a:field
	let separatorLength=strlen(a:separator)
	let start=0
	let end=match(a:line, a:separator)
	if (end < 0)
		let end=strlen(a:line)
	endi

	" search for requested field
	while (start < strlen(a:line) && counter > 0)
		let counter=counter-separatorLength
		let start=end+separatorLength
		let end=match(a:line, a:separator, start)
		if (end < 0)
			let end=strlen(a:line)
		endi
	endw

	if (start < strlen(a:line))
		return strpart(a:line, start, end-start)
	else
		return ""
	endi
endf
" Section: Command definitions {{{1
com! GPGViewRecipients call s:GPGViewRecipients()
com! GPGEditRecipients call s:GPGEditRecipients()

" vim600: set foldmethod=marker:
