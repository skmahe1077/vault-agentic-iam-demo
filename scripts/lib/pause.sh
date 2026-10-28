pause() {
  if [ -t 0 ]; then
    read -r -p "" _ || true
  fi
}
