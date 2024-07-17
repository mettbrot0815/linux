import os
import subprocess
import time
import requests
import zipfile
import curses
from termcolor import colored
from curses import wrapper

# URLs for downloading Tor and Proxifier
TOR_URL = "https://www.torproject.org/dist/torbrowser/11.0.1/tor-win64-0.4.6.8.zip"
PROXIFIER_URL = "https://www.proxifier.com/download/ProxifierSetup.exe"

# Paths for the downloads
TOR_ZIP_PATH = "tor.zip"
PROXIFIER_PATH = "ProxifierSetup.exe"
TOR_INSTALL_PATH = "C:\\Tor"

def download_file(url, dest_path):
    response = requests.get(url, stream=True)
    with open(dest_path, 'wb') as f:
        for chunk in response.iter_content(chunk_size=8192):
            f.write(chunk)

def extract_zip(file_path, extract_to):
    with zipfile.ZipFile(file_path, 'r') as zip_ref:
        zip_ref.extractall(extract_to)

def install_tor():
    print(colored("Downloading Tor...", "yellow"))
    download_file(TOR_URL, TOR_ZIP_PATH)
    print(colored("Extracting Tor...", "yellow"))
    extract_zip(TOR_ZIP_PATH, TOR_INSTALL_PATH)
    print(colored("Tor installation complete.", "green"))

def install_proxifier():
    print(colored("Downloading Proxifier...", "yellow"))
    download_file(PROXIFIER_URL, PROXIFIER_PATH)
    print(colored("Installing Proxifier...", "yellow"))
    subprocess.run([PROXIFIER_PATH, "/silent"])
    print(colored("Proxifier installation complete.", "green"))

def start_tor():
    tor_exe = os.path.join(TOR_INSTALL_PATH, "Tor", "tor.exe")
    subprocess.Popen([tor_exe])
    print(colored("Starting Tor...", "yellow"))
    time.sleep(10)  # Wait for Tor to start
    print(colored("Tor started.", "green"))

def stop_tor():
    subprocess.run(["taskkill", "/F", "/IM", "tor.exe"])
    print(colored("Tor stopped.", "green"))

def configure_proxifier():
    # Example: You need to create a Proxifier rule manually and save it as a .pxw file
    proxifier_config_path = "C:\\Path\\To\\ProxifierConfig.pxw"
    print(colored("Configuring Proxifier...", "yellow"))
    subprocess.run(["ProxifierCLI.exe", "addrule", "127.0.0.1:9050", "-config", proxifier_config_path])
    print(colored("Proxifier configured.", "green"))

def verify_tor():
    print(colored("Verifying Tor connection...", "yellow"))
    result = subprocess.run(["curl", "--socks5", "127.0.0.1:9050", "https://check.torproject.org/"], capture_output=True, text=True)
    if "Congratulations. This browser is configured to use Tor." in result.stdout:
        print(colored("Tor is successfully configured!", "green"))
    else:
        print(colored("Tor configuration failed.", "red"))
        print(result.stdout)

def main_menu(stdscr):
    curses.curs_set(0)
    stdscr.clear()
    stdscr.refresh()

    menu = [
        "Install Tor and Proxifier",
        "Configure Proxifier",
        "Start Tor",
        "Stop Tor",
        "Verify Tor Connection",
        "Exit"
    ]

    current_row = 0

    while True:
        stdscr.clear()
        stdscr.addstr(0, 0, "Anonymity Setup Tool", curses.A_BOLD | curses.A_UNDERLINE)
        stdscr.addstr(1, 0, "Use arrow keys to navigate and Enter to select.")
        for idx, item in enumerate(menu):
            if idx == current_row:
                stdscr.addstr(idx + 2, 0, item, curses.color_pair(1))
            else:
                stdscr.addstr(idx + 2, 0, item)
        stdscr.refresh()

        key = stdscr.getch()

        if key == curses.KEY_UP and current_row > 0:
            current_row -= 1
        elif key == curses.KEY_DOWN and current_row < len(menu) - 1:
            current_row += 1
        elif key == curses.KEY_ENTER or key in [10, 13]:
            if current_row == len(menu) - 1:
                break
            stdscr.clear()
            stdscr.refresh()
            if current_row == 0:
                install_tor()
            elif current_row == 1:
                configure_proxifier()
            elif current_row == 2:
                start_tor()
            elif current_row == 3:
                stop_tor()
            elif current_row == 4:
                verify_tor()

        time.sleep(1)

def main(stdscr):
    curses.start_color()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_WHITE)

    main_menu(stdscr)

if __name__ == "__main__":
    wrapper(main)
