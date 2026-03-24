KDIR ?= /lib/modules/$(shell uname -r)/build
obj-m := thunderbolt_net.o
thunderbolt_net-y := main.o trace.o

ccflags-y := -I$(src)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
