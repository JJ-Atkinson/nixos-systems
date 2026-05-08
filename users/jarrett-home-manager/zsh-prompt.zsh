autoload -Uz add-zsh-hook
autoload -U colors && colors
zmodload zsh/datetime

setopt prompt_subst

_prompt_command_started_at=0
_prompt_command_duration=""
_prompt_git_segment=""
_prompt_nix_shell_segment=""
_prompt_ssh_segment=""

_prompt_epoch_ms() {
  local epoch="$1"
  local seconds="${epoch%.*}"
  local fraction="${epoch#*.}"
  fraction="${fraction}000"

  printf '%d' $(( seconds * 1000 + ${fraction[1,3]} ))
}

_prompt_preexec() {
  _prompt_command_started_at=$(_prompt_epoch_ms "$EPOCHREALTIME")
  printf '[%s] %s\n' "$(strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS)" "$1"
}

_prompt_precmd() {
  local last_status=$?

  _prompt_command_duration=""
  if (( _prompt_command_started_at > 0 )); then
    local elapsed_ms=$(( $(_prompt_epoch_ms "$EPOCHREALTIME") - _prompt_command_started_at ))
    local elapsed_display=""

    if (( elapsed_ms > 50 )); then
      if (( elapsed_ms < 1000 )); then
        elapsed_display="${elapsed_ms}ms"
      elif (( elapsed_ms < 60000 )); then
        elapsed_display=$(printf '%.3fs' $(( elapsed_ms / 1000.0 )))
      else
        elapsed_display="$(( elapsed_ms / 60000 ))m $(( (elapsed_ms % 60000) / 1000 ))s"
      fi

      _prompt_command_duration=" %{$fg[cyan]%}${elapsed_display}%{$reset_color%}"
    fi
  fi
  _prompt_command_started_at=0

  if (( last_status == 0 )); then
    _prompt_status="%{$fg_bold[green]%}${_PROMPT_OK_GLYPH:-✓}%{$reset_color%}"
  else
    _prompt_status="%{$fg_bold[red]%}${_PROMPT_FAIL_GLYPH:-✗} ${last_status}%{$reset_color%}"
  fi

  _prompt_git_segment="$(_prompt_git_info)"
  _prompt_nix_shell_segment="$(_prompt_nix_shell_info)"
  _prompt_ssh_segment="$(_prompt_ssh_info)"
}

_prompt_git_info() {
  local branch
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=$(git rev-parse --short HEAD 2>/dev/null) || return

  if [[ -n "$(git status --porcelain --ignore-submodules=dirty 2>/dev/null)" ]]; then
    if (( ${#branch} > 19 )); then
      printf '%%{%%F{250}%%}(%%{%%F{yellow}%%}%s%%{%%F{blue}%%}[...]%%{%%F{250}%%})%%{%%F{yellow}%%}*%%{%%f%%} ' "${branch[1,15]}"
    else
      printf '%%{%%F{250}%%}(%%{%%F{yellow}%%}%s%%{%%F{250}%%})%%{%%F{yellow}%%}*%%{%%f%%} ' "$branch"
    fi
  else
    if (( ${#branch} > 19 )); then
      printf '%%{%%F{250}%%}(%%{%%F{green}%%}%s%%{%%F{blue}%%}[...]%%{%%F{250}%%})%%{%%f%%} ' "${branch[1,15]}"
    else
      printf '%%{%%F{250}%%}(%%{%%F{green}%%}%s%%{%%F{250}%%})%%{%%f%%} ' "$branch"
    fi
  fi
}

_prompt_nix_shell_info() {
  local depth="${WITH_PROGRAM_NIX_SHELL_DEPTH:-0}"

  if (( depth == 0 )); then
    [[ -n "$IN_NIX_SHELL" ]] || return
    depth=1
  fi

  if (( depth > 1 )); then
    printf '%%{%%F{blue}%%}NxSh%s%%{%%f%%}' "$depth"
  else
    printf '%%{%%F{blue}%%}NxSh%%{%%f%%}'
  fi
}

_prompt_ssh_info() {
  [[ -n "$SSH_CONNECTION$SSH_CLIENT$SSH_TTY" ]] || return

  printf '%%{%%F{250}%%}[%%{%%F{blue}%%}ssh:%%{%%F{magenta}%%}%s%%{%%F{250}%%}]%%{%%f%%} ' "${HOST%%.*}"
}

add-zsh-hook preexec _prompt_preexec
add-zsh-hook precmd _prompt_precmd

PROMPT='${_prompt_status}${_prompt_command_duration} %{$fg[cyan]%}%~%{$reset_color%} ${_prompt_git_segment}${_prompt_ssh_segment}${_prompt_nix_shell_segment}%{$fg_bold[green]%}>%{$reset_color%} '
