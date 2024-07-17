import os
import subprocess
import time
import curses
from termcolor import colored
from curses import wrapper

def install_packages():
    print(colored("Updating package list and installing Tor and Proxychains...", "yellow"))
    subprocess.run(["sudo", "apt", "update"], check=True)
    subprocess.run(["sudo", "apt", "install", "-y", "tor", "proxychains4"], check=True)
    print(colored("Installation complete.", "green"))

def configure_proxychains():
    print(colored("Configuring Proxychains...", "yellow"))
    proxychains_conf = """
dynamic_chain
proxy_dns
tcp_read_time_out 15000
tcp_connect_time_out 8000

[ProxyList]
socks5  127.0.0.1 9050
    """
    with open("/etc/proxychains4.conf", "w") as conf_file:
        conf_file.write(proxychains_conf)
    print(colored("Proxychains configuration complete.", "green"))

def start_tor():
    print(colored("Starting Tor service...", "yellow"))
    subprocess.run(["sudo", "systemctl", "start", "tor"], check=True)
    time.sleep(10)  # Wait for Tor to start
    print(colored("Tor service started.", "green"))

def stop_tor():
    print(colored("Stopping Tor service...", "yellow"))
    subprocess.run(["sudo", "systemctl", "stop", "tor"], check=True)
    print(colored("Tor service stopped.", "green"))

def verify_tor():
    print(colored("Verifying Tor connection...", "yellow"))
    result = subprocess.run(["proxychains4", "curl", "https://check.torproject.org/"], capture_output=True, text=True)
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
        "Install Tor and Proxychains",
        "Configure Proxychains",
        "Start Tor",
        "Stop Tor",
        "Verify Tor Connection",
        "Exit"
    ]

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
                install_packages()
            elif current_row == 1:
                configure_proxychains()
            elif current_row == 2:
                start_tor()
            elif current_row == 3:
                stop_tor()
            elif current_row == 4:
                verify_tor()

        time.sleep(1)

def main(stdscr):
    global current_row
    current_row = 0

    curses.start_color()
    curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_WHITE)

    main_menu(stdscr)

if __name__ == "__main__":
    wrapper(main)
