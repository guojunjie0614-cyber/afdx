"""Dual-network RX mechanism: trace one frame through storage and decisions.

Uses the local CIM_RC style primitives retained in the preceding style study.
Example: VL 7, SN 17, each network PSN=16, initial rm_last=16;
valid configuration, both checks enabled, within skew window, queue has room.
Both descriptors pending: A is processed first. Addresses are illustrative.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'rx_ring_cim_style'))
from circuit_primitives import *

# Physical points at the final 160 mm print width. Match the reference's
# visual weight at comparable figure width, rather than copying the thinner
# strokes of its single-column print. Keep internal grids subordinate.
FS_TITLE = 9.0
FS_MODULE = 8.0
FS_LABEL = 7.3
FS_NOTE = 6.7
FS_DATA = 8.2
LW_MAIN = 1.4
LW_DETAIL = 0.9
LW_DATA = 1.6
ARROW_HEAD = 11.5
INK = '#000000'


def label(ax,x,y,s,size=FS_LABEL,color=INK,bold=True,ha='center',**kw):
    return text(ax,x,y,s,size,color,ha,weight='bold' if bold else 'normal',**kw)

def bytes_row(ax,x,y,cell=7,h=7,fill=CYAN_FILL,released=False):
    for i in range(4):
        p=rect(ax,x+i*cell,y,cell,h,fill,INK,LW_DETAIL)
        if released:
            p.set_hatch('///');p.set_edgecolor(MID)
        label(ax,x+(i+.5)*cell,y+h/2,rf'$p_{i}$',FS_DATA,
              GRAY if released else INK,
              **({'bbox':dict(facecolor=fill,edgecolor='none',pad=.3)} if released else {}))
    if released:rect(ax,x,y,4*cell,h,'none',INK,LW_MAIN,zorder=5)

def stage(ax,x,y,title,sub):
    rect(ax,x,y,20,12,'white',INK,LW_MAIN)
    label(ax,x+10,y+3.7,title,FS_MODULE,INK,True)
    label(ax,x+10,y+8.6,sub,FS_NOTE)

def pointer(ax,x,y,s,color=INK,ha='center'):
    label(ax,x,y-4,s,FS_LABEL,color,True,ha)
    arrow(ax,[(x,y-2.5),(x,y)],color,LW_MAIN,ms=ARROW_HEAD)

def build():
    # Typography and strokes are specified in points, independent of coordinates.
    plt.rcParams['hatch.linewidth'] = 0.56
    fig,ax=canvas(178,151)
    ax.set_aspect('auto')
    fig.set_size_inches(160/25.4, 120/25.4)
    panel(ax,4,4,'(a) Dual-network reception',FS_TITLE)
    for x,net,start in [(7,'A',100),(47,'B',200)]:
        label(ax,x+16,11,f'Network {net}',FS_MODULE,INK,True)
        for dx,w,s,fill in [(0,11,'VL 7',LIGHT),(11,11,'SN 17',PEACH),(22,10,r'$P_{17}$',CYAN_FILL)]:
            rect(ax,x+dx,15,w,7,fill,INK,LW_DETAIL)
            label(ax,x+dx+w/2,18.5,s,FS_LABEL)
        rect(ax,x,29,32,9,'white',INK,LW_MAIN)
        label(ax,x+16,33.5,'MAC + parser',FS_MODULE,INK,True)
        arrow(ax,[(x+16,22),(x+16,29)],INK,LW_MAIN,ms=ARROW_HEAD)
        arrow(ax,[(x+10,38),(x+10,49)],CYAN,LW_DATA,ms=ARROW_HEAD)
        label(ax,x+12,44,'prewrite',FS_LABEL,CYAN_DARK,True,'left')
        rect(ax,x,49,32,22,LIGHT,INK,LW_MAIN)
        label(ax,x+16,53,f'ring {net} · 4 KiB',FS_LABEL,INK,True)
        bytes_row(ax,x+2,57)
        label(ax,x+16,68,f'addr. {start}–{start+3}',FS_NOTE)

    # Align decision hardware with the input headers; keep payload below it.
    rect(ax,87,11,87,39,LAVENDER,INK,LW_MAIN,zorder=0)
    label(ax,130.5,15,'Shared RX engine',FS_MODULE,INK,True)
    mux(ax,90,21,5,16,'',INK,lw=LW_MAIN)
    label(ax,92.5,43,'A/B',FS_NOTE)
    arrow(ax,[(39,32),(42,32),(42,24),(90,24)],INK,LW_MAIN,ms=ARROW_HEAD)
    crossover(ax,63,24,INK,LW_MAIN)
    label(ax,72,24,'desc A',FS_LABEL,INK,True,
          bbox=dict(facecolor='white',edgecolor='none',pad=.5),zorder=8)
    arrow(ax,[(79,32),(90,32)],INK,LW_MAIN,ms=ARROW_HEAD)
    label(ax,85,40,'desc B',FS_NOTE,INK,True,'right')
    for x,title,sub in [(100,'IC','SN / PSN'),(123,'RM','SN / time'),(146,'Admit','queue room')]:
        stage(ax,x,23,title,sub)
    for xa,xb in [(95,100),(120,123),(143,146)]:
        arrow(ax,[(xa,29),(xb,29)],INK,LW_MAIN,ms=ARROW_HEAD)
    rect(ax,100,39.5,43,9,LIGHT,INK,LW_DETAIL)
    label(ax,121.5,42,'PSN_A / PSN_B',FS_LABEL)
    label(ax,121.5,46,'Shared RM record',FS_LABEL)
    # Separate read and write directions in this short inter-row gap.
    arrow(ax,[(108,39.5),(108,35)],INK,LW_DETAIL,ms=ARROW_HEAD)
    arrow(ax,[(112,35),(112,39.5)],INK,LW_DETAIL,ms=ARROW_HEAD)
    arrow(ax,[(133,39.5),(133,35)],INK,LW_DETAIL,ms=ARROW_HEAD)
    arrow(ax,[(161,35),(161,46),(143,46)],GREEN_DARK,LW_MAIN,ms=ARROW_HEAD)
    label(ax,166,48.5,'RM update',FS_NOTE,GREEN_DARK,True,'right')

    # Resolution is a control result; its concrete effect is expanded in (c).
    arrow(ax,[(156,35),(156,42),(148,42),(148,51.5)],PURPLE,LW_MAIN,ms=ARROW_HEAD,dashed=True)
    label(ax,146,53.5,'resolve / commit → (c)',FS_NOTE,PURPLE_DARK)

    label(ax,145,58,'rx_dq · accepted descriptor',FS_LABEL,INK,True)
    fields=[(118,14,'A'),(132,19,'100'),(151,19,'4')]
    for x,w,s in fields:
        rect(ax,x,61,w,7,GREEN_FILL,INK,LW_MAIN)
        label(ax,x+w/2,64.5,s,FS_MODULE,GREEN_DARK,True)
    arrow(ax,[(166,29),(172,29),(172,64.5),(170,64.5)],INK,LW_MAIN,ms=ARROW_HEAD)
    label(ax,141.5,70.8,'start',FS_LABEL,INK)
    label(ax,160.5,70.8,'length',FS_LABEL,INK)
    arrow(ax,[(125,68),(125,70),(109,70),(109,63),(102.5,63),(102.5,68)],INK,LW_DETAIL,ms=ARROW_HEAD)

    # Short read paths run just below the rings to the delivery selector.
    arrow(ax,[(39,61),(43,61),(43,77),(100,77)],CYAN,LW_DATA,ms=ARROW_HEAD)
    arrow(ax,[(79,61),(84,61),(84,71),(100,71)],CYAN,LW_DATA,ms=ARROW_HEAD)
    mux(ax,100,68,5,12,'',INK,lw=LW_MAIN)
    label(ax,105,60,'net select',FS_NOTE)
    arrow(ax,[(105,74),(115,74),(115,78),(124,78)],CYAN,LW_DATA,ms=ARROW_HEAD)
    rect(ax,124,74,23,9,'white',INK,LW_MAIN)
    label(ax,135.5,78.5,'RX deliver',FS_LABEL,INK,True)
    arrow(ax,[(136,68),(136,74)],INK,LW_MAIN,ms=ARROW_HEAD)
    bytes_row(ax,151,75,6,7,GREEN_FILL)
    arrow(ax,[(147,78.5),(151,78.5)],CYAN,LW_DATA,ms=ARROW_HEAD)
    label(ax,163,86,'One delivery',FS_LABEL,GREEN_DARK,True)

    panel(ax,4,93,'(b) Same VL / SN: process A, then B',FS_TITLE)
    # A small executable example ties IC, RM and publishing to the architecture.
    widths=[12,11,27,27,29,18,45]
    headers=['Net','SN','IC: local PSN=16','RM record','RM result','commit','Queue write']
    rows=[['A','17','Pass','16 → 17','New frame','1','{A, 100, 4}'],
          ['B','17','Pass','17 → 17','Duplicate','0','—']]
    x=5
    for w,h in zip(widths,headers):
        rect(ax,x,98,w,6,LIGHT,INK,LW_DETAIL)
        label(ax,x+w/2,101,h,FS_NOTE,INK,True)
        x+=w
    for ri,row in enumerate(rows):
        x=5;y=104+ri*6
        for ci,(w,s) in enumerate(zip(widths,row)):
            fill=GREEN_FILL if ri==0 and ci>=4 else PURPLE_FILL if ri==1 and ci>=4 else 'white'
            rect(ax,x,y,w,6,fill,INK,LW_DETAIL)
            col=RED if ci==3 or ci==5 else INK
            label(ax,x+w/2,y+3,s,FS_LABEL,col,True)
            x+=w

    panel(ax,4,123,'(c) Commit and rollback',FS_TITLE)
    memory_y = 131
    for x,net,start,accept in [(7,'A',100,True),(96,'B',200,False)]:
        col=GREEN_DARK if accept else PURPLE_DARK
        label(ax,x,memory_y+4,f'{net}:',FS_MODULE,INK,True,'left')
        bx=x+17
        rect(ax,bx-6,memory_y,6,8,GREEN_FILL,INK,LW_DETAIL)
        label(ax,bx-3,memory_y+4,'…',FS_MODULE,GRAY)
        bytes_row(ax,bx,memory_y,10,8,GREEN_FILL if accept else LIGHT,released=not accept)
        rect(ax,bx+40,memory_y,9,8,'white',INK,LW_DETAIL)
        label(ax,bx+44.5,memory_y+4,'…',FS_MODULE,GRAY)
        old=bx if accept else bx+40
        new=bx+40 if accept else bx
        line(ax,[(old,memory_y-3),(old,memory_y+10)],GRAY,LW_DETAIL,dashed=True)
        pointer(ax,new,memory_y,'commit = trial',col)
        if accept:
            arrow(ax,[(bx,memory_y+13),(bx+40,memory_y+13)],col,LW_MAIN,ms=ARROW_HEAD)
            label(ax,bx+20,memory_y+17,f'commit: {start} → {start+4}',FS_LABEL,col,True)
        else:
            arrow(ax,[(bx+40,memory_y+13),(bx,memory_y+13)],col,LW_MAIN,ms=ARROW_HEAD)
            label(ax,bx+20,memory_y+17,f'trial: {start+4} → {start}',FS_LABEL,col,True)
    return fig


if __name__=='__main__':
    fig=build()
    for extension in ('svg','pdf','png'):
        fig.savefig(HERE/f'dual_rx_mechanism.{extension}',dpi=300,facecolor='white')
    print(HERE/'dual_rx_mechanism.png')
