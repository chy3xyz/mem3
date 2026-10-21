# Incremental consolidation — raw A/B runs

Produced by `mem3-consolidate-bench` (`examples/consolidate_bench.zig`), long-run corpus shape, 400 cells ingested between passes, threshold 0.75, ReleaseFast, Apple M1 Pro. **Host load average was 55–80 on 10 cores**: wall time is unreliable, CPU time is less so, ratios are what to read. `base` = `main` at 03e588f; `new` = this branch. Runs were interleaved base,new,base,new per size. `pairs` for `base` is analytic n(n-1)/2 (the all-pairs loop's exact count); for `new` it is counted. `cons_live` is bytes the consolidator's own allocator holds after the pass (the cache); `digest` is an order-independent hash of every abstract's text and importance.

Reproduce: `zig build example-consolidate-bench`, then e.g. `./zig-out/bin/mem3-consolidate-bench --mode=jump --cells=45000 --passes=3`. The baseline binary is built by dropping the same file into a checkout of the old tree and `zig build-exe --dep mem3 -Mroot=examples/consolidate_bench.zig -Mmem3=src/lib.zig -OReleaseFast -lc`.


## Jump mode (ingest N cells, then 3 passes: pass 1 cold, 2–3 steady)


### res_20000_base_1

```
# mode=jump cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
pass=1 cells=20000 clusters=180 abstracts=180 pairs=199990000 wall_ms=13950.22 cpu_ms=11543.23 cons_live=1440 cons_peak=1836400 peak_rss_kb=13840
pass=2 cells=20580 clusters=155 abstracts=155 pairs=211757910 wall_ms=15078.47 cpu_ms=12198.42 cons_live=2680 cons_peak=1878712 peak_rss_kb=14016
pass=3 cells=21135 clusters=155 abstracts=155 pairs=223333545 wall_ms=36099.92 cpu_ms=13365.25 cons_live=3920 cons_peak=1927054 peak_rss_kb=14320
# digest=e81e5312ae5868a2 total_abstracts=490
```

### res_20000_base_2

```
# mode=jump cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
pass=1 cells=20000 clusters=180 abstracts=180 pairs=199990000 wall_ms=16418.81 cpu_ms=11707.05 cons_live=1440 cons_peak=1836400 peak_rss_kb=13552
pass=2 cells=20580 clusters=155 abstracts=155 pairs=211757910 wall_ms=13762.49 cpu_ms=12217.80 cons_live=2680 cons_peak=1878712 peak_rss_kb=15424
pass=3 cells=21135 clusters=155 abstracts=155 pairs=223333545 wall_ms=16618.86 cpu_ms=13002.24 cons_live=3920 cons_peak=1927054 peak_rss_kb=15504
# digest=e81e5312ae5868a2 total_abstracts=490
```

### res_20000_new_1

```
# mode=jump cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
pass=1 cells=20000 clusters=180 abstracts=180 pairs=199990000 wall_ms=33433.61 cpu_ms=12328.44 cons_live=2275497 cons_peak=2835629 peak_rss_kb=12912
pass=2 cells=20580 clusters=155 abstracts=155 pairs=11767910 wall_ms=1130.92 cpu_ms=818.53 cons_live=2276737 cons_peak=2853109 peak_rss_kb=14752
pass=3 cells=21135 clusters=155 abstracts=155 pairs=11575635 wall_ms=1053.98 cpu_ms=810.88 cons_live=2952473 cons_peak=3544381 peak_rss_kb=14992
# digest=e81e5312ae5868a2 total_abstracts=490
# cache_bytes=2948529 cached_cells=21135
```

### res_20000_new_2

```
# mode=jump cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
pass=1 cells=20000 clusters=180 abstracts=180 pairs=199990000 wall_ms=12812.13 cpu_ms=11578.85 cons_live=2275497 cons_peak=2835629 peak_rss_kb=15248
pass=2 cells=20580 clusters=155 abstracts=155 pairs=11767910 wall_ms=1044.96 cpu_ms=808.82 cons_live=2276737 cons_peak=2853109 peak_rss_kb=15776
pass=3 cells=21135 clusters=155 abstracts=155 pairs=11575635 wall_ms=865.01 cpu_ms=795.97 cons_live=2952473 cons_peak=3544381 peak_rss_kb=16400
# digest=e81e5312ae5868a2 total_abstracts=490
# cache_bytes=2948529 cached_cells=21135
```

### res_45000_base_1

```
# mode=jump cells=45000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
pass=1 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=70802.51 cpu_ms=58071.61 cons_live=1440 cons_peak=4158334 peak_rss_kb=27088
pass=2 cells=45580 clusters=155 abstracts=155 pairs=1038745410 wall_ms=120866.41 cpu_ms=61360.77 cons_live=2680 cons_peak=4185080 peak_rss_kb=30704
pass=3 cells=46135 clusters=155 abstracts=155 pairs=1064196045 wall_ms=82783.24 cpu_ms=62075.25 cons_live=3920 cons_peak=4234128 peak_rss_kb=30752
# digest=e81e5312ae7c0bbc total_abstracts=490
```

### res_45000_base_2

```
# mode=jump cells=45000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
pass=1 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=88923.61 cpu_ms=59828.72 cons_live=1440 cons_peak=4158334 peak_rss_kb=27504
pass=2 cells=45580 clusters=155 abstracts=155 pairs=1038745410 wall_ms=80878.90 cpu_ms=60751.82 cons_live=2680 cons_peak=4185080 peak_rss_kb=30704
pass=3 cells=46135 clusters=155 abstracts=155 pairs=1064196045 wall_ms=85961.59 cpu_ms=62370.93 cons_live=3920 cons_peak=4234128 peak_rss_kb=30704
# digest=e81e5312ae7c0bbc total_abstracts=490
```

### res_45000_new_1

```
# mode=jump cells=45000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
pass=1 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=90801.41 cpu_ms=60635.64 cons_live=5013402 cons_peak=6273534 peak_rss_kb=24816
pass=2 cells=45580 clusters=155 abstracts=155 pairs=26267910 wall_ms=1845.35 cpu_ms=1775.15 cons_live=5014642 cons_peak=6291014 peak_rss_kb=29344
pass=3 cells=46135 clusters=155 abstracts=155 pairs=25450635 wall_ms=1887.75 cpu_ms=1743.99 cons_live=5015882 cons_peak=6307790 peak_rss_kb=29584
# digest=e81e5312ae7c0bbc total_abstracts=490
# cache_bytes=5011938 cached_cells=46135
```

### res_45000_new_2

```
# mode=jump cells=45000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
pass=1 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=66878.44 cpu_ms=58888.91 cons_live=5013402 cons_peak=6273534 peak_rss_kb=25424
pass=2 cells=45580 clusters=155 abstracts=155 pairs=26267910 wall_ms=1846.34 cpu_ms=1786.72 cons_live=5014642 cons_peak=6291014 peak_rss_kb=31872
pass=3 cells=46135 clusters=155 abstracts=155 pairs=25450635 wall_ms=1758.15 cpu_ms=1736.07 cons_live=5015882 cons_peak=6307790 peak_rss_kb=32112
# digest=e81e5312ae7c0bbc total_abstracts=490
# cache_bytes=5011938 cached_cells=46135
```

### res_5000_base_1

```
# mode=jump cells=5000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
pass=1 cells=5000 clusters=180 abstracts=180 pairs=12497500 wall_ms=850.03 cpu_ms=756.32 cons_live=1440 cons_peak=487376 peak_rss_kb=5840
pass=2 cells=5580 clusters=155 abstracts=155 pairs=15565410 wall_ms=953.66 cpu_ms=914.76 cons_live=2680 cons_peak=533280 peak_rss_kb=6240
pass=3 cells=6135 clusters=155 abstracts=155 pairs=18816045 wall_ms=1112.28 cpu_ms=1095.09 cons_live=3920 cons_peak=577486 peak_rss_kb=6800
# digest=e81e5312ae4d9bc2 total_abstracts=490
```

### res_5000_base_2

```
# mode=jump cells=5000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
pass=1 cells=5000 clusters=180 abstracts=180 pairs=12497500 wall_ms=754.25 cpu_ms=737.04 cons_live=1440 cons_peak=487376 peak_rss_kb=5776
pass=2 cells=5580 clusters=155 abstracts=155 pairs=15565410 wall_ms=984.94 cpu_ms=926.62 cons_live=2680 cons_peak=533280 peak_rss_kb=6128
pass=3 cells=6135 clusters=155 abstracts=155 pairs=18816045 wall_ms=1230.19 cpu_ms=1123.07 cons_live=3920 cons_peak=577486 peak_rss_kb=6368
# digest=e81e5312ae4d9bc2 total_abstracts=490
```

### res_5000_new_1

```
# mode=jump cells=5000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
pass=1 cells=5000 clusters=180 abstracts=180 pairs=12497500 wall_ms=818.63 cpu_ms=784.86 cons_live=642997 cons_peak=783129 peak_rss_kb=6432
pass=2 cells=5580 clusters=155 abstracts=155 pairs=3067910 wall_ms=232.51 cpu_ms=212.31 cons_live=644237 cons_peak=800609 peak_rss_kb=6800
pass=3 cells=6135 clusters=155 abstracts=155 pairs=3250635 wall_ms=228.06 cpu_ms=223.83 cons_live=656961 cons_peak=828869 peak_rss_kb=7056
# digest=e81e5312ae4d9bc2 total_abstracts=490
# cache_bytes=653017 cached_cells=6135
```

### res_5000_new_2

```
# mode=jump cells=5000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
pass=1 cells=5000 clusters=180 abstracts=180 pairs=12497500 wall_ms=815.65 cpu_ms=785.68 cons_live=642997 cons_peak=783129 peak_rss_kb=6528
pass=2 cells=5580 clusters=155 abstracts=155 pairs=3067910 wall_ms=301.09 cpu_ms=216.43 cons_live=644237 cons_peak=800609 peak_rss_kb=6976
pass=3 cells=6135 clusters=155 abstracts=155 pairs=3250635 wall_ms=365.80 cpu_ms=238.88 cons_live=656961 cons_peak=828869 peak_rss_kb=7200
# digest=e81e5312ae4d9bc2 total_abstracts=490
# cache_bytes=653017 cached_cells=6135
```

## Jump mode with forgetting (`--forget=K` cells removed before each pass after the first; the 45k K=400 second run was interrupted and is empty)


### forget_20000_base

```
# mode=jump cells=20000 add=400 passes=4 seed=42 threshold=0.75 forget=50 pairs_kind=analytic
pass=1 forgotten=0 rebuilt=0 cells=20000 clusters=180 abstracts=180 pairs=199990000 wall_ms=14064.90 cpu_ms=11624.97 cons_live=1440 cons_peak=1836400 peak_rss_kb=13648
pass=2 forgotten=50 rebuilt=0 cells=20530 clusters=155 abstracts=155 pairs=210730185 wall_ms=15812.45 cpu_ms=12186.38 cons_live=2680 cons_peak=1875112 peak_rss_kb=13904
pass=3 forgotten=50 rebuilt=0 cells=21035 clusters=155 abstracts=155 pairs=221225095 wall_ms=14260.34 cpu_ms=12677.54 cons_live=3920 cons_peak=1919160 peak_rss_kb=15424
pass=4 forgotten=50 rebuilt=0 cells=21540 clusters=155 abstracts=155 pairs=231975030 wall_ms=15355.41 cpu_ms=13247.57 cons_live=5160 cons_peak=1964488 peak_rss_kb=15696
# digest=4cea82905df7df05 total_abstracts=645
```

### forget_20000_new

```
# mode=jump cells=20000 add=400 passes=4 seed=42 threshold=0.75 forget=50 pairs_kind=counted
pass=1 forgotten=0 rebuilt=0 cells=20000 clusters=180 abstracts=180 pairs=199990000 wall_ms=12545.06 cpu_ms=11608.11 cons_live=2275497 cons_peak=2835629 peak_rss_kb=15328
pass=2 forgotten=50 rebuilt=46 cells=20530 clusters=155 abstracts=155 pairs=11990770 wall_ms=857.56 cpu_ms=826.63 cons_live=2277069 cons_peak=2852041 peak_rss_kb=15328
pass=3 forgotten=50 rebuilt=42 cells=21035 clusters=155 abstracts=155 pairs=12267041 wall_ms=865.22 cpu_ms=845.78 cons_live=2278309 cons_peak=2867417 peak_rss_kb=15536
pass=4 forgotten=50 rebuilt=45 cells=21540 clusters=155 abstracts=155 pairs=12451446 wall_ms=857.99 cpu_ms=849.28 cons_live=2954045 cons_peak=3557297 peak_rss_kb=15776
# digest=4cea82905df7df05 total_abstracts=645
# cache_bytes=2948861 cached_cells=21540
```

### forget_45000_k0_1

```
# mode=jump cells=45000 add=400 passes=4 seed=42 threshold=0.75 forget=0 pairs_kind=counted
pass=1 forgotten=0 rebuilt=0 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=62912.15 cpu_ms=57924.76 cons_live=5013402 cons_peak=6273534 peak_rss_kb=26672
pass=2 forgotten=0 rebuilt=0 cells=45580 clusters=155 abstracts=155 pairs=26267910 wall_ms=1857.86 cpu_ms=1790.94 cons_live=5014642 cons_peak=6291014 peak_rss_kb=28416
pass=3 forgotten=0 rebuilt=0 cells=46135 clusters=155 abstracts=155 pairs=25450635 wall_ms=1800.87 cpu_ms=1744.89 cons_live=5015882 cons_peak=6307790 peak_rss_kb=28752
pass=4 forgotten=0 rebuilt=0 cells=46690 clusters=155 abstracts=155 pairs=25758660 wall_ms=1790.42 cpu_ms=1747.14 cons_live=5017122 cons_peak=6324574 peak_rss_kb=29824
# digest=4cea82905e24dde2 total_abstracts=645
# cache_bytes=5011938 cached_cells=46690
```

### forget_45000_k0_2

```
# mode=jump cells=45000 add=400 passes=4 seed=42 threshold=0.75 forget=0 pairs_kind=counted
pass=1 forgotten=0 rebuilt=0 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=63624.00 cpu_ms=58251.16 cons_live=5013402 cons_peak=6273534 peak_rss_kb=25264
pass=2 forgotten=0 rebuilt=0 cells=45580 clusters=155 abstracts=155 pairs=26267910 wall_ms=1770.69 cpu_ms=1753.35 cons_live=5014642 cons_peak=6291014 peak_rss_kb=29568
pass=3 forgotten=0 rebuilt=0 cells=46135 clusters=155 abstracts=155 pairs=25450635 wall_ms=1705.80 cpu_ms=1695.52 cons_live=5015882 cons_peak=6307790 peak_rss_kb=30192
pass=4 forgotten=0 rebuilt=0 cells=46690 clusters=155 abstracts=155 pairs=25758660 wall_ms=1746.04 cpu_ms=1723.99 cons_live=5017122 cons_peak=6324574 peak_rss_kb=30448
# digest=4cea82905e24dde2 total_abstracts=645
# cache_bytes=5011938 cached_cells=46690
```

### forget_45000_k400_1

```
# mode=jump cells=45000 add=400 passes=4 seed=42 threshold=0.75 forget=400 pairs_kind=counted
pass=1 forgotten=0 rebuilt=0 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=62138.46 cpu_ms=58245.21 cons_live=5013402 cons_peak=6273534 peak_rss_kb=25136
pass=2 forgotten=399 rebuilt=160 cells=45181 clusters=155 abstracts=155 pairs=30416476 wall_ms=2659.67 cpu_ms=2224.68 cons_live=5016394 cons_peak=6281590 peak_rss_kb=29184
pass=3 forgotten=396 rebuilt=135 cells=45340 clusters=155 abstracts=155 pairs=33006452 wall_ms=2360.43 cpu_ms=2327.15 cons_live=5017634 cons_peak=6287286 peak_rss_kb=29456
pass=4 forgotten=393 rebuilt=137 cells=45502 clusters=155 abstracts=155 pairs=33068308 wall_ms=2369.69 cpu_ms=2337.41 cons_live=5018874 cons_peak=6293062 peak_rss_kb=29712
# digest=4cea82905e225b46 total_abstracts=645
# cache_bytes=5013690 cached_cells=45502
```

### forget_45000_k400_2

```
# mode=jump cells=45000 add=400 passes=4 seed=42 threshold=0.75 forget=400 pairs_kind=counted
```

### forget_45000_k50_1

```
# mode=jump cells=45000 add=400 passes=4 seed=42 threshold=0.75 forget=50 pairs_kind=counted
pass=1 forgotten=0 rebuilt=0 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=60061.35 cpu_ms=57866.06 cons_live=5013402 cons_peak=6273534 peak_rss_kb=25136
pass=2 forgotten=50 rebuilt=44 cells=45530 clusters=155 abstracts=155 pairs=27502699 wall_ms=1997.46 cpu_ms=1888.73 cons_live=5014974 cons_peak=6289946 peak_rss_kb=29440
pass=3 forgotten=50 rebuilt=40 cells=46035 clusters=155 abstracts=155 pairs=28939395 wall_ms=2014.69 cpu_ms=1992.04 cons_live=5016214 cons_peak=6305322 peak_rss_kb=29696
pass=4 forgotten=48 rebuilt=42 cells=46542 clusters=155 abstracts=155 pairs=29545558 wall_ms=2048.52 cpu_ms=2024.94 cons_live=5017454 cons_peak=6320762 peak_rss_kb=29904
# digest=4cea82905e24dde2 total_abstracts=645
# cache_bytes=5012270 cached_cells=46542
```

### forget_45000_k50_2

```
# mode=jump cells=45000 add=400 passes=4 seed=42 threshold=0.75 forget=50 pairs_kind=counted
pass=1 forgotten=0 rebuilt=0 cells=45000 clusters=180 abstracts=180 pairs=1012477500 wall_ms=59041.72 cpu_ms=57597.55 cons_live=5013402 cons_peak=6273534 peak_rss_kb=25264
pass=2 forgotten=50 rebuilt=44 cells=45530 clusters=155 abstracts=155 pairs=27502699 wall_ms=1883.66 cpu_ms=1869.54 cons_live=5014974 cons_peak=6289946 peak_rss_kb=29760
pass=3 forgotten=50 rebuilt=40 cells=46035 clusters=155 abstracts=155 pairs=28939395 wall_ms=2001.61 cpu_ms=1983.67 cons_live=5016214 cons_peak=6305322 peak_rss_kb=30528
pass=4 forgotten=48 rebuilt=42 cells=46542 clusters=155 abstracts=155 pairs=29545558 wall_ms=2053.42 cpu_ms=2030.75 cons_live=5017454 cons_peak=6320762 peak_rss_kb=30720
# digest=4cea82905e24dde2 total_abstracts=645
# cache_bytes=5012270 cached_cells=46542
```

## Grow mode (empty → N, one pass per 400 cells; summarised, one line per file)


### grow_20000_base_1

```
# mode=grow cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
# digest=6a1e9bc256836b16 total_abstracts=5689
37 passes; first: pass=1 cells=400 clusters=158 abstracts=118 pairs=79800 wall_ms=10.44 cpu_ms=9.17 cons_live=944 cons_peak=66768 peak_rss_kb=2992
last: pass=37 cells=20334 clusters=155 abstracts=155 pairs=206725611 wall_ms=12085.51 cpu_ms=11666.88 cons_live=45512 cons_peak=1920075 peak_rss_kb=13952
sum cpu_ms=150653 sum pairs=2628928113
```

### grow_20000_base_2

```
# mode=grow cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=analytic
# digest=6a1e9bc256836b16 total_abstracts=5689
37 passes; first: pass=1 cells=400 clusters=158 abstracts=118 pairs=79800 wall_ms=9.67 cpu_ms=8.97 cons_live=944 cons_peak=66768 peak_rss_kb=2992
last: pass=37 cells=20334 clusters=155 abstracts=155 pairs=206725611 wall_ms=14636.04 cpu_ms=12008.72 cons_live=45512 cons_peak=1920075 peak_rss_kb=12672
sum cpu_ms=154602 sum pairs=2628928113
```

### grow_20000_new_1

```
# mode=grow cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
# digest=6a1e9bc256836b16 total_abstracts=5689
# cache_bytes=2274033 cached_cells=20334
37 passes; first: pass=1 cells=400 clusters=158 abstracts=118 pairs=79800 wall_ms=13.58 cpu_ms=12.18 cons_live=53542 cons_peak=65194 peak_rss_kb=3200
last: pass=37 cells=20334 clusters=155 abstracts=155 pairs=11131080 wall_ms=764.97 cpu_ms=750.44 cons_live=2319569 cons_peak=2889053 peak_rss_kb=14800
sum cpu_ms=14039 sum pairs=206725611
```

### grow_20000_new_2

```
# mode=grow cells=20000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
# digest=6a1e9bc256836b16 total_abstracts=5689
# cache_bytes=2274033 cached_cells=20334
37 passes; first: pass=1 cells=400 clusters=158 abstracts=118 pairs=79800 wall_ms=12.71 cpu_ms=11.72 cons_live=53542 cons_peak=65194 peak_rss_kb=3152
last: pass=37 cells=20334 clusters=155 abstracts=155 pairs=11131080 wall_ms=888.39 cpu_ms=769.52 cons_live=2319569 cons_peak=2889053 peak_rss_kb=14208
sum cpu_ms=14291 sum pairs=206725611
```

### grow_45000_new_1

```
# mode=grow cells=45000 add=400 passes=3 seed=42 threshold=0.75 pairs_kind=counted
# digest=2202f4da357d10f0 total_abstracts=12664
# cache_bytes=5011938 cached_cells=45309
82 passes; first: pass=1 cells=400 clusters=158 abstracts=118 pairs=79800 wall_ms=12.01 cpu_ms=11.28 cons_live=53542 cons_peak=65194 peak_rss_kb=3104
last: pass=82 cells=45309 clusters=155 abstracts=155 pairs=24992205 wall_ms=2349.62 cpu_ms=1746.88 cons_live=5113274 cons_peak=6382054 peak_rss_kb=26016
sum cpu_ms=71343 sum pairs=1026430086
```
