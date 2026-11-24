BEGIN {
    status=ENVIRON["TRADER_CHART_STATUS"]
    if (color) {
        up="\033[38;5;43m"
        down="\033[38;5;203m"
        average="\033[38;5;221m"
        muted="\033[38;5;245m"
        reset="\033[0m"
    }
}
{
    timestamp[NR]=$1
    open[NR]=$2
    high[NR]=$3
    low[NR]=$4
    closing[NR]=$5
    vol[NR]=$6
    # Sum the actual window to avoid cancellation from much older prices.
    if (NR>=20) {
        total=0
        for (i=NR-19; i<=NR; i++) total+=closing[i]
        ma[NR]=total/20
    }
}
function level(price) {
    return int((ceiling-price)/(ceiling-floor)*(height-1)+0.5)
}
function clocklabel(n, format) {
    format=interval=="1d" ? "%Y-%m-%d" : "%m-%d %H:%M"
    return strftime(format,timestamp[n])
}
function axis(price, label) {
    label=sprintf("%.8g",price)
    if (length(label)>14) label=sprintf("%.7g",price)
    return sprintf("%14s",label)
}
END {
    if (NR==0) exit 1
    if (cols<34 || rows<12) {
        printf "%.*s\n",cols-1,"Resize terminal to 34x12."
        exit
    }
    # Leave a spare column so drawing the final cell cannot wrap the frame.
    cols--
    last=NR-offset
    if (last<1) last=1
    count=bars
    if (count>cols-16) count=cols-16
    if (count>last) count=last
    first=last-count+1
    height=rows-8
    if (height>32) height=32
    ceiling=high[first]
    floor=low[first]
    for (n=first; n<=last; n++) {
        if (high[n]>ceiling) ceiling=high[n]
        if (low[n]<floor) floor=low[n]
        if (sma && (n in ma)) {
            if (ma[n]>ceiling) ceiling=ma[n]
            if (ma[n]<floor) floor=ma[n]
        }
        if (vol[n]!="-") {
            volume_known++
            if (vol[n]+0>maxvol) maxvol=vol[n]+0
        }
    }
    margin=(ceiling-floor)*0.05
    if (!margin) margin=(ceiling<0 ? -ceiling : ceiling)*0.001+0.00000001
    ceiling+=margin
    floor-=margin
    change=last>1 ? closing[last]-closing[last-1] : 0
    direction=change<0 ? down : up
    title=sprintf("%s  %s  %s  %.8g",symbol,interval,exchange,closing[last])
    printf "%s%.*s%s\n",direction,cols,title,reset
    details=sprintf("O %.8g  H %.8g  L %.8g  C %.8g",open[last],high[last],low[last],closing[last])
    if (last>1 && closing[last-1]!=0) details=details sprintf("  %+.2f%%",100*change/closing[last-1])
    printf "%.*s\n",cols,details
    details=status (offset ? " | History" : " | Latest") (sma ? " | SMA 20" : "")
    # Truncate status to the terminal width.
    printf "%.*s\n",cols,details
    for (n=first; n<=last; n++) {
        top[n]=level(high[n]); bottom[n]=level(low[n])
        a=level(open[n]); b=level(closing[n])
        bodytop[n]=a<b ? a : b
        bodybottom[n]=a>b ? a : b
        ink[n]=closing[n]>=open[n] ? up : down
        if (sma && (n in ma)) maline[n]=level(ma[n])
    }
    tick=int((height-1)/4)
    if (tick<1) tick=1
    for (r=0; r<height; r++) {
        grid=r%tick==0 || r==height-1
        printf "%s%s %s%s",muted,grid ? axis(ceiling-r*(ceiling-floor)/(height-1)) : sprintf("%14s",""), grid ? "+" : "|",reset
        for (n=first; n<=last; n++) {
            if (r>=bodytop[n] && r<=bodybottom[n])
                printf "%s%s%s",ink[n],(closing[n]>=open[n] ? "█" : "▓"),reset
            else if (r>=top[n] && r<=bottom[n]) printf "%s│%s",ink[n],reset
            else if ((n in maline) && r==maline[n]) printf "%s•%s",average,reset
            else printf "%s%s%s",muted,grid ? "┄" : " ",reset
        }
        printf "\n"
    }
    if (volume) {
        # Unknown volume gets a marker instead of being shown as zero.
        printf "%14s  ",volume_known ? "Volume" : "Volume n/a"
        split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █",blocks," ")
        for (n=first; n<=last; n++) {
            v=maxvol && vol[n]+0>0 ? int(7*vol[n]/maxvol)+1 : 0
            printf "%s%s%s",ink[n],vol[n]=="-" ? "?" : (v ? blocks[v] : " "),reset
        }
        printf "\n"
    }
    left=clocklabel(first); right=clocklabel(last)
    if (count>=length(left)+length(right)+1)
        printf "%16s%s%*s%s\n","",left,count-length(left)-length(right),"",right
    else
        printf "%16s%s\n","",right
    printf "%16s%s\n","","UTC"
}
