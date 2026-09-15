#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
loop_cpu_worker.py —— 占空比可控的浮点负载发生器

用途
    当香橙派上没有 stress-ng 时，作为 loop_workload.sh --mode synthetic 的
    底层负载单元。每个进程按指定占空比做浮点/矩阵运算，模拟 SLAM 的计算特征。

    它【只】产生 CPU/内存负载。真实负载还包含网络与存储 IO，
    若要用合成负载代表真实全栈，请配合 loop_workload.sh 的 --io / --net 选项。

用法
    python3 loop_cpu_worker.py --load 0.6            # 60% 占空比，跑到被杀死
    python3 loop_cpu_worker.py --load 0.85 --chunk-ms 20

参数
    --load      0~1，繁忙时间占比（目标 CPU 占用率）
    --chunk-ms  每个 忙/闲 周期的长度，默认 20 ms
                （周期越短，负载越平滑；但调度开销占比越高）
"""

import argparse
import math
import time


def busy_work(deadline):
    """在 deadline 之前持续做浮点运算，返回迭代次数。

    用矩阵乘 + 超越函数混合，逼近 SLAM 后端的计算特征（NEON/FP 密集）。
    """
    x = 1.000001
    a = [1.0 / (i + 1.0) for i in range(64)]
    b = [0.5 + i * 1e-3 for i in range(64)]
    n = 0
    while True:
        s = 0.0
        for i in range(64):
            s += a[i] * b[i]
            a[i] = a[i] * x + 1e-9
        # 超越函数：FP 单元压力更大
        s = math.sqrt(abs(s) + 1.0) + math.sin(s) * math.cos(s)
        for i in range(64):
            b[i] = b[i] * 0.999999 + s * 1e-12
        n += 1
        # 每 64 次迭代查一次时钟，避免 syscall 成为瓶颈
        if n & 0x3F == 0 and time.perf_counter() >= deadline:
            return n


def main():
    ap = argparse.ArgumentParser(description='占空比可控的浮点负载发生器')
    ap.add_argument('--load', type=float, default=0.6,
                    help='繁忙时间占比 0~1（目标 CPU 占用率）')
    ap.add_argument('--chunk-ms', type=float, default=20.0,
                    help='一个 忙+闲 周期的长度（毫秒）')
    args = ap.parse_args()

    load = max(0.0, min(1.0, args.load))
    chunk = max(1.0, args.chunk_ms) / 1000.0
    busy_t = chunk * load
    idle_t = chunk - busy_t

    next_t = time.perf_counter()
    while True:
        if busy_t > 0:
            busy_work(next_t + busy_t)
        next_t += chunk
        if idle_t > 0:
            now = time.perf_counter()
            if next_t > now:
                time.sleep(next_t - now)
            else:
                # 落后了（系统繁忙），重新对齐，避免追逐
                next_t = now


if __name__ == '__main__':
    main()
