"""Browse photos on the Ti60 OV5640 album firmware and export 720p PNGs."""

from base64 import b64encode
from datetime import datetime
from pathlib import Path
from queue import Empty, Queue
from threading import Event, Thread
import time
import tkinter as tk
from tkinter import filedialog, ttk

import serial
from serial.tools.list_ports import comports

from ov5640_capture import STORED_BAUD, STORED_SIZE, encode_png, read_exact, read_snapshot, save_png


THUMB_SIZE = (160, 90)
OUTPUT_DIR = Path(__file__).resolve().parents[1] / "data" / "ov5640_capture"


def open_port(device):
    return serial.Serial(device, STORED_BAUD, timeout=0.15, write_timeout=2)


def read_album(port):
    port.reset_input_buffer()
    port.write(b"L")
    try:
        reply = read_exact(port, 7, time.monotonic() + 2)
    except TimeoutError as exc:
        raise ValueError("未收到相册信息。请确认串口和 Ti60 相册位流。") from exc
    count, capacity, flags = reply[4:]
    if reply[:4] != b"OVA1" or not 1 <= capacity <= 64 or count > capacity:
        raise ValueError("相册信息格式错误，请重新读取相册。")
    return count, capacity, flags


def read_photo(port, number, thumbnail=False):
    if not 1 <= number <= 64:
        raise ValueError("照片编号超出范围。")
    port.write((b"T" if thumbnail else b"G") + bytes([number]))
    size = THUMB_SIZE if thumbnail else STORED_SIZE
    return read_snapshot(port, timeout=4 if thumbnail else 45, frame_size=size, stored=True)


class AlbumWindow:
    def __init__(self, window):
        self.window = window
        self.device = tk.StringVar()
        self.summary = tk.StringVar(value="尚未读取")
        self.preview_title = tk.StringVar(value="照片预览")
        self.status = tk.StringVar(value="选择板载 CH340N 的串口，点击「读取相册」。")
        self.loaded_device = None
        self.photo_count = 0
        self.photo_image = None
        self.working = False
        self.closing = False
        self.stop = Event()
        self.events = Queue()

        window.title("Ti60 拍照相册")
        window.geometry("820x520")
        window.minsize(720, 450)
        window.protocol("WM_DELETE_WINDOW", self.close)
        theme = ttk.Style(window)
        theme.theme_use("clam")
        theme.configure("TFrame", background="#f0f4f8")
        theme.configure("TLabel", background="#f0f4f8", foreground="#203349",
                        font=("Microsoft YaHei UI", 10))
        theme.configure("Heading.TLabel", font=("Microsoft YaHei UI", 19, "bold"))
        theme.configure("TButton", font=("Microsoft YaHei UI", 10), padding=(12, 7))
        theme.configure("Accent.TButton", background="#205f9d", foreground="#ffffff")
        theme.map("Accent.TButton", background=[("active", "#184c80")],
                  foreground=[("disabled", "#a9b8c5")])

        main = ttk.Frame(window, padding=(22, 18))
        main.pack(fill="both", expand=True)
        ttk.Label(main, text="Ti60 拍照相册", style="Heading.TLabel").pack(anchor="w")
        toolbar = ttk.Frame(main, padding=(0, 14))
        toolbar.pack(fill="x")
        ttk.Label(toolbar, text="串口").pack(side="left", padx=(0, 8))
        self.ports = ttk.Combobox(toolbar, textvariable=self.device, width=11,
                                  postcommand=self.refresh_ports)
        self.ports.pack(side="left", padx=(0, 8))
        self.refresh_button = ttk.Button(toolbar, text="读取相册", command=self.refresh,
                                         style="Accent.TButton")
        self.refresh_button.pack(side="left")
        ttk.Label(toolbar, textvariable=self.summary).pack(side="right")

        pane = ttk.Frame(main)
        pane.pack(fill="both", expand=True)
        sidebar = ttk.Frame(pane)
        sidebar.pack(side="left", fill="y", padx=(0, 16))
        self.photos = tk.Listbox(sidebar, width=17, font=("Microsoft YaHei UI", 11),
                                 bg="#ffffff", fg="#203349", selectbackground="#205f9d",
                                 selectforeground="#ffffff", relief="flat", highlightthickness=1,
                                 highlightbackground="#c4d2df", highlightcolor="#205f9d",
                                 exportselection=False, activestyle="none")
        scroll = ttk.Scrollbar(sidebar, orient="vertical", command=self.photos.yview)
        self.photos.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        self.photos.pack(side="left", fill="both", expand=True)
        self.photos.bind("<<ListboxSelect>>", self.preview)

        viewer = ttk.Frame(pane)
        viewer.pack(side="left", fill="both", expand=True)
        ttk.Label(viewer, textvariable=self.preview_title).pack(anchor="w", pady=(0, 8))
        self.image_label = tk.Label(viewer, bg="#16293c", fg="#d6e5f3",
                                    font=("Microsoft YaHei UI", 11), text="选择一张照片查看")
        self.image_label.pack(fill="both", expand=True)

        actions = ttk.Frame(main, padding=(0, 14, 0, 9))
        actions.pack(fill="x")
        self.export_button = ttk.Button(actions, text="导出选中", command=self.export_one)
        self.export_button.pack(side="left", padx=(0, 8))
        self.all_button = ttk.Button(actions, text="全部导出", command=self.export_all)
        self.all_button.pack(side="left", padx=(0, 8))
        self.stop_button = ttk.Button(actions, text="停止导出", command=self.stop_export)
        self.stop_button.pack(side="left")
        ttk.Label(main, textvariable=self.status, wraplength=675).pack(anchor="w", fill="x")

        ports = self.refresh_ports()
        preferred = next((port.device for port in ports if "CH340" in port.description.upper()), None)
        if preferred or len(ports) == 1:
            self.device.set(preferred or ports[0].device)
        self.set_controls()

    def refresh_ports(self):
        ports = sorted(comports(), key=lambda port: port.device)
        self.ports.configure(values=[port.device for port in ports])
        return ports

    def selected(self):
        selection = self.photos.curselection()
        return selection[0] + 1 if selection else None

    def set_controls(self, batch=False):
        self.ports.configure(state="disabled" if self.working else "normal")
        self.photos.configure(state="disabled" if self.working else "normal")
        self.refresh_button.configure(state="disabled" if self.working else "normal")
        available = not self.working and self.photo_count > 0
        self.export_button.configure(state="normal" if available and self.selected() else "disabled")
        self.all_button.configure(state="normal" if available else "disabled")
        self.stop_button.configure(state="normal" if batch else "disabled")

    def run(self, message, task, completed, batch=False):
        self.working = True
        self.stop.clear()
        self.status.set(message)
        self.set_controls(batch)

        def work():
            try:
                self.events.put(("done", task()))
            except (OSError, ValueError) as exc:
                self.events.put(("error", str(exc)))

        Thread(target=work, daemon=True).start()
        self.window.after(40, self.poll, completed)

    def poll(self, completed):
        try:
            while True:
                kind, result = self.events.get_nowait()
                if kind == "progress":
                    if not self.stop.is_set():
                        self.status.set(result)
                    continue
                self.working = False
                if self.closing:
                    self.window.destroy()
                    return
                self.set_controls()
                if kind == "done":
                    completed(result)
                else:
                    self.status.set("读取或保存失败。 " + result)
                return
        except Empty:
            self.window.after(40, self.poll, completed)

    def refresh(self):
        device = self.device.get().strip()
        if not device:
            self.status.set("请先选择或输入串口名称。")
            return

        def task():
            with open_port(device) as port:
                return read_album(port)

        def completed(result):
            count, capacity, flags = result
            self.loaded_device = device
            self.photo_count = count
            self.summary.set(f"已存 {count} / {capacity} 张")
            self.photos.delete(0, "end")
            for number in range(1, count + 1):
                self.photos.insert("end", f"照片 {number:02d}")
            self.photo_image = None
            self.preview_title.set("照片预览")
            self.image_label.configure(image="", text="选择一张照片查看" if count else "相册为空")
            if flags & 2:
                self.status.set("板子正在拍摄，请稍后重新读取相册。")
            elif flags & 4:
                self.status.set("板子报告拍摄或读图错误，已收录的照片仍可导出。")
            elif flags & 1:
                self.status.set("相册已满，可导出已有照片。" if count == capacity else
                                "相册已更新。继续按 K1 拍照后，可重新读取相册。")
            else:
                self.status.set("等板上 LED1、LED2、LED3 亮后，按 K1 拍照。")
            self.set_controls()

        self.run("正在读取相册……", task, completed)

    def ready_to_read(self):
        if self.working:
            return False
        if self.device.get().strip() != self.loaded_device:
            self.status.set("请先读取当前串口的相册。")
            return False
        return True

    def preview(self, _event=None):
        number = self.selected()
        if number is None or not self.ready_to_read():
            return
        device = self.loaded_device
        self.preview_title.set(f"照片 {number:02d}")
        self.image_label.configure(image="", text="")

        def task():
            with open_port(device) as port:
                port.reset_input_buffer()
                return read_photo(port, number, thumbnail=True)

        def completed(image):
            thumbnail = tk.PhotoImage(data=b64encode(encode_png(*image)), format="png")
            self.photo_image = thumbnail.zoom(2, 2)
            self.image_label.configure(image=self.photo_image, text="")
            self.status.set("缩略图已读取。导出将保存原始 1280×720 图像。")

        self.run("正在读取缩略图……", task, completed)

    def export_one(self):
        number = self.selected()
        if number is None or not self.ready_to_read():
            return
        filename = filedialog.asksaveasfilename(parent=self.window, defaultextension=".png",
                    filetypes=[("PNG 图片", "*.png")], initialfile=f"ov5640_{number:02d}.png")
        if filename:
            path = Path(filename)
            if path.exists() or path.suffix.lower() != ".png":
                self.status.set("请选择一个尚未使用的 PNG 文件名。")
                return
            self.export([number], path)

    def export_all(self):
        if not self.ready_to_read():
            return
        directory = filedialog.askdirectory(parent=self.window, mustexist=True,
                    initialdir=OUTPUT_DIR if OUTPUT_DIR.exists() else OUTPUT_DIR.parent)
        if directory:
            name = datetime.now().strftime("ov5640_%Y%m%d_%H%M%S_%f")
            self.export(range(1, self.photo_count + 1), Path(directory) / name, batch=True)

    def export(self, numbers, destination, batch=False):
        device = self.loaded_device

        def task():
            with open_port(device) as port:
                port.reset_input_buffer()
                total = 0
                for number in numbers:
                    if self.stop.is_set():
                        break
                    self.events.put(("progress", f"正在导出照片 {number:02d}，每张约 20 秒……"))
                    path = destination / f"ov5640_{number:02d}.png" if batch else destination
                    save_png(path, *read_photo(port, number))
                    total += 1
                return total

        def completed(total):
            self.status.set(f"已导出 {total} 张。 {destination}")

        self.run("正在开始导出……", task, completed, batch)

    def stop_export(self):
        self.stop.set()
        self.stop_button.configure(state="disabled")
        self.status.set("当前照片保存完成后停止。")

    def close(self):
        if self.working:
            self.closing = True
            self.stop_export()
        else:
            self.window.destroy()


if __name__ == "__main__":
    root = tk.Tk()
    AlbumWindow(root)
    root.mainloop()
