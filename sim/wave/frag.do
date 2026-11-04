# 分片与重组：一条 8192 字节应用消息在发送端按 IP 分成 6 片，每片间隔一个 BAG，
# 同时从 A、B 两网发出；接收端收齐后一次交付完整消息。只用公开应用口和 GMII，
# 不注入错误帧。窗口和光标按本次仿真记录计算，并先核对记录再截图。
source [file join [pwd] sim wave common.do]
wave_setup frag tb_fragmentation
set tb /tb_fragmentation
set frag_vl 0x0103
set frag_length 8192
set frag_lmax 1471
set frag_bag_us 1000

# tb_fragmentation 在运行开始时读取 vectors/；wave_setup 已切到本次输出目录。
set payload_hex ""
set fh [open vectors/payload.hex w]
for {set i 0} {$i < $frag_length} {incr i} {
    set byte [format %02x [expr {($i * 19 + 37) & 255}]]
    puts $fh $byte
    append payload_hex $byte
}
close $fh
set fh [open vectors/config.txt w]
puts $fh 1
puts $fh "[expr {$frag_vl}] $frag_bag_us $frag_lmax 1000 2000"
close $fh
set fh [open vectors/schedule.txt w]
puts $fh "1 $frag_length 1"
puts $fh "0 [expr {$frag_vl}] $frag_length 0"
close $fh
set fh [open vectors/injection.txt w]
puts $fh "0 0"
close $fh

wave_signal $tb/input_valid app_tx_valid binary
wave_signal $tb/input_data app_tx_data
wave_signal $tb/av gmii_tx_en_a binary
wave_signal $tb/a gmii_txd_a
wave_signal $tb/bv gmii_tx_en_b binary
wave_signal $tb/b gmii_txd_b
wave_signal $tb/output_valid app_rx_valid binary
wave_signal $tb/output_data app_rx_data
wave_signal $tb/rn rx_bytes unsigned
wave_signal $tb/deliveries deliveries unsigned
run -all

proc frag_records {name} {
    set fh [open $name r]
    set rows {}
    foreach line [split [read $fh] "\n"] {
        if {[string trim $line] ne ""} {lappend rows [split [string trim $line] " "]}
    }
    close $fh
    return $rows
}
# 第 c 拍上升沿在 (c-1)*8+4 ns；测试台在该沿采样到的是上一拍驱动的字节。
proc frag_edge {cycle} {expr {($cycle - 1) * 8 + 4}}

if {[examine -radix unsigned $tb/errors] != 0 || [examine -radix unsigned $tb/deliveries] != 1} {
    error "tb_fragmentation self-check failed or delivery count is not 1"
}
set messages {}
foreach row [frag_records tx_messages.txt] {
    if {[lindex $row 0] ne "E"} {lappend messages $row}
}
if {[llength $messages] != 1} {error "Expected one application input message"}
lassign [lindex $messages 0] input_first input_last input_vl input_length
if {$input_vl != [expr {$frag_vl}] || $input_length != $frag_length} {error "Input record mismatch"}
set rx [frag_records rx.txt]
if {[llength $rx] != 1} {error "Expected one reassembled delivery"}
lassign [lindex $rx 0] output_first output_last output_vl output_payload
if {$output_vl ne [format %04x [expr {$frag_vl}]] || $output_payload ne $payload_hex} {
    error "Reassembled delivery differs from the application input"
}
set frames_a [frag_records tx_a.txt]
set frames_b [frag_records tx_b.txt]
# 两网帧在同一拍开始；源 MAC 的网络号和 FCS 按网络不同，IP 头起的内容必须相同。
if {[llength $frames_a] != [llength $frames_b]} {error "A and B networks sent different frame counts"}
foreach frame_a $frames_a frame_b $frames_b {
    lassign $frame_a start_a wire_a
    lassign $frame_b start_b wire_b
    if {$start_a != $start_b || [string length $wire_a] != [string length $wire_b] ||
        [string range $wire_a 44 end-8] ne [string range $wire_b 44 end-8]} {
        error "A and B fragments differ at cycle $start_a"
    }
}
# 每片 IP 数据不超过 Lmax+8 且按 8 字节对齐；末片 MF=0。
set capacity [expr {min(1479, $frag_lmax + 8)}]
set remaining [expr {$frag_length + 8}]
set position 0
set expected {}
while {$remaining > 0} {
    set part [expr {$remaining <= $capacity ? $remaining : ($capacity / 8) * 8}]
    set remaining [expr {$remaining - $part}]
    lappend expected [list $position [expr {$remaining > 0}]]
    incr position $part
}
if {[llength $frames_a] != [llength $expected]} {error "Unexpected fragment count"}
set previous ""
foreach frame $frames_a want $expected {
    lassign $frame start wire
    # 7 字节前导码、SFD、14 字节以太网头之后为 IP 头；标志/片偏移在 IP 头第 6--7 字节。
    scan [string range $wire 56 59] %x field
    if {[list [expr {($field & 0x1fff) * 8}] [expr {($field >> 13) & 1}]] ne $want} {
        error "Fragment offset or MF flag mismatch at cycle $start"
    }
    if {$previous ne "" && $start - $previous < $frag_bag_us * 125} {error "Fragments closer than one BAG"}
    set previous $start
}
lassign [lindex $frames_a 0] first_start first_wire
lassign [lindex $frames_a end] last_start last_wire
set last_end [expr {$last_start + [string length $last_wire] / 2}]
if {$output_first <= $last_end} {error "Delivery must start after the last fragment ends"}
set offsets {}
foreach item $expected {lappend offsets [lindex $item 0]}
puts "FRAG_CHECK PASS fragments=[llength $frames_a] payload=$frag_length offsets=[join $offsets ,]"

set input_start [expr {($input_first - 1) * 8}]
set first_fragment [frag_edge [expr {$first_start - 1}]]
set last_fragment [frag_edge [expr {$last_start - 1}]]
set delivery_start [frag_edge [expr {$output_first - 1}]]
set delivery_end [frag_edge $output_last]

set cursor_a [wave cursor add -time ${input_start}ns -name App_input]
set cursor_b [wave cursor add -time ${delivery_end}ns -name Delivery_end]
wave_snapshot frag_1 [expr {$input_start - 50000}]ns [expr {$delivery_end + 50000}]ns
catch {wave cursor delete $cursor_b}
catch {wave cursor delete $cursor_a}

set cursor_a [wave cursor add -time ${last_fragment}ns -name Last_fragment]
set cursor_b [wave cursor add -time ${delivery_start}ns -name Delivery_start]
wave_snapshot frag_2 [expr {$last_fragment - 3000}]ns [expr {$delivery_end + 4000}]ns
catch {wave cursor delete $cursor_b}
catch {wave cursor delete $cursor_a}

# 首片 IP 头：版本/长度 45 00，总长 05 d4，标识，标志/片偏移 20 00（MF=1，偏移 0）。
set flags_byte [expr {$first_fragment + 28 * 8}]
set cursor_a [wave cursor add -time ${flags_byte}ns -name Flags_offset]
wave_snapshot frag_3 [expr {$first_fragment + 20 * 8}]ns [expr {$first_fragment + 44 * 8}]ns
catch {wave cursor delete $cursor_a}
wave zoom range [expr {$input_start - 50000}]ns [expr {$delivery_end + 50000}]ns
