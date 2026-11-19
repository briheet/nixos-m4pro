// SPDX-License-Identifier: GPL-2.0-only
/*
 * Polled serial console on the Apple dockchannel UART.
 *
 * On the M4 Pro (J614s) the host reaches this FIFO over debug USB
 * (/dev/cu.kis-100000-ch-0 after `macvdmtool debugusb`). uart0 is not
 * routed there, so this is the console that can be seen.
 *
 * The node covers the data window at /arm-io/dockchannel-uart reg 0 +
 * 0x4000. Offsets are from m1n1's src/dockchannel_uart.c, rebased onto that
 * window so an earlycon fixmap of one 16K page reaches every register.
 * Receive data sits in bits 15:8 of the RX register.
 *
 * No interrupts: a timer polls RX and refills TX.
 */
#include <linux/console.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/serial_core.h>
#include <linux/timer.h>
#include <linux/tty.h>
#include <linux/tty_flip.h>

#define DC_TX8		0x04
#define DC_TX_FREE	0x14
#define DC_RX8		0x1c
#define DC_RX_COUNT	0x2c

#define DC_DEV_NAME	"ttyDC"
#define DC_POLL_MS	5
#define DC_TX_SPIN	100000

struct dc_port {
	struct uart_port port;
	struct timer_list timer;
};

static struct dc_port dc_ports[1];

static bool dc_tx_ready(struct uart_port *port)
{
	return readl_relaxed(port->membase + DC_TX_FREE) != 0;
}

static void dc_put(struct uart_port *port, unsigned char c)
{
	writel_relaxed(c, port->membase + DC_TX8);
}

/* Console and earlycon: wait for room, but never forever. */
static void dc_console_putchar(struct uart_port *port, unsigned char c)
{
	int spin = DC_TX_SPIN;

	while (!dc_tx_ready(port) && --spin)
		cpu_relax();
	dc_put(port, c);
}

static void dc_tx_chars(struct uart_port *port)
{
	u8 ch;

	uart_port_tx(port, ch, dc_tx_ready(port), dc_put(port, ch));
}

static void dc_rx_chars(struct uart_port *port)
{
	u32 count = readl_relaxed(port->membase + DC_RX_COUNT);
	bool got = false;

	while (count--) {
		u8 c = readl_relaxed(port->membase + DC_RX8) >> 8;

		port->icount.rx++;
		if (!uart_handle_sysrq_char(port, c))
			uart_insert_char(port, 0, 0, c, TTY_NORMAL);
		got = true;
	}
	if (got)
		tty_flip_buffer_push(&port->state->port);
}

static void dc_poll(struct timer_list *t)
{
	struct dc_port *dc = timer_container_of(dc, t, timer);
	struct uart_port *port = &dc->port;
	unsigned long flags;

	uart_port_lock_irqsave(port, &flags);
	dc_rx_chars(port);
	dc_tx_chars(port);
	uart_port_unlock_irqrestore(port, flags);

	mod_timer(&dc->timer, jiffies + msecs_to_jiffies(DC_POLL_MS));
}

static unsigned int dc_tx_empty(struct uart_port *port)
{
	return TIOCSER_TEMT;
}

static void dc_set_mctrl(struct uart_port *port, unsigned int mctrl)
{
}

static unsigned int dc_get_mctrl(struct uart_port *port)
{
	return TIOCM_CAR | TIOCM_CTS | TIOCM_DSR;
}

static void dc_stop_tx(struct uart_port *port)
{
}

static void dc_start_tx(struct uart_port *port)
{
	dc_tx_chars(port);
}

static void dc_stop_rx(struct uart_port *port)
{
}

static int dc_startup(struct uart_port *port)
{
	struct dc_port *dc = container_of(port, struct dc_port, port);

	timer_setup(&dc->timer, dc_poll, 0);
	mod_timer(&dc->timer, jiffies + msecs_to_jiffies(DC_POLL_MS));
	return 0;
}

static void dc_shutdown(struct uart_port *port)
{
	struct dc_port *dc = container_of(port, struct dc_port, port);

	timer_delete_sync(&dc->timer);
}

static void dc_set_termios(struct uart_port *port, struct ktermios *termios,
			   const struct ktermios *old)
{
	/* A FIFO, not a line: no baud rate or framing to program. */
	termios->c_cflag &= ~(CSIZE | CSTOPB | PARENB);
	termios->c_cflag |= CS8;
}

static const char *dc_type(struct uart_port *port)
{
	return "dockchannel";
}

static void dc_release_port(struct uart_port *port)
{
}

static int dc_request_port(struct uart_port *port)
{
	return 0;
}

static void dc_config_port(struct uart_port *port, int flags)
{
	if (flags & UART_CONFIG_TYPE)
		port->type = PORT_GENERIC;
}

static const struct uart_ops dc_ops = {
	.tx_empty	= dc_tx_empty,
	.set_mctrl	= dc_set_mctrl,
	.get_mctrl	= dc_get_mctrl,
	.stop_tx	= dc_stop_tx,
	.start_tx	= dc_start_tx,
	.stop_rx	= dc_stop_rx,
	.startup	= dc_startup,
	.shutdown	= dc_shutdown,
	.set_termios	= dc_set_termios,
	.type		= dc_type,
	.release_port	= dc_release_port,
	.request_port	= dc_request_port,
	.config_port	= dc_config_port,
};

static void dc_console_write(struct console *co, const char *s, unsigned int count)
{
	struct uart_port *port = &dc_ports[co->index].port;
	unsigned long flags;
	int locked = 1;

	if (oops_in_progress)
		locked = uart_port_trylock_irqsave(port, &flags);
	else
		uart_port_lock_irqsave(port, &flags);

	uart_console_write(port, s, count, dc_console_putchar);

	if (locked)
		uart_port_unlock_irqrestore(port, flags);
}

static int dc_console_setup(struct console *co, char *options)
{
	if (co->index < 0 || co->index >= ARRAY_SIZE(dc_ports))
		co->index = 0;
	if (!dc_ports[co->index].port.membase)
		return -ENODEV;
	return 0;
}

static struct uart_driver dc_uart_driver;

static struct console dc_console = {
	.name	= DC_DEV_NAME,
	.write	= dc_console_write,
	.device	= uart_console_device,
	.setup	= dc_console_setup,
	.flags	= CON_PRINTBUFFER,
	.index	= -1,
	.data	= &dc_uart_driver,
};

static struct uart_driver dc_uart_driver = {
	.owner		= THIS_MODULE,
	.driver_name	= "apple-dockchannel-uart",
	.dev_name	= DC_DEV_NAME,
	.nr		= ARRAY_SIZE(dc_ports),
	.cons		= &dc_console,
};

static int dc_probe(struct platform_device *pdev)
{
	struct uart_port *port = &dc_ports[0].port;
	struct resource *res;

	port->membase = devm_platform_get_and_ioremap_resource(pdev, 0, &res);
	if (IS_ERR(port->membase))
		return PTR_ERR(port->membase);

	port->mapbase = res->start;
	port->dev = &pdev->dev;
	port->iotype = UPIO_MEM32;
	port->ops = &dc_ops;
	port->line = 0;
	port->fifosize = 1;
	port->type = PORT_GENERIC;
	port->flags = UPF_BOOT_AUTOCONF;
	port->has_sysrq = IS_ENABLED(CONFIG_SERIAL_APPLE_DOCKCHANNEL);

	platform_set_drvdata(pdev, port);
	return uart_add_one_port(&dc_uart_driver, port);
}

static void dc_remove(struct platform_device *pdev)
{
	uart_remove_one_port(&dc_uart_driver, platform_get_drvdata(pdev));
}

static const struct of_device_id dc_of_match[] = {
	{ .compatible = "apple,dockchannel-uart" },
	{ }
};
MODULE_DEVICE_TABLE(of, dc_of_match);

static struct platform_driver dc_platform_driver = {
	.probe	= dc_probe,
	.remove	= dc_remove,
	.driver	= {
		.name		= "apple-dockchannel-uart",
		.of_match_table	= dc_of_match,
	},
};

static int __init dc_init(void)
{
	int ret = uart_register_driver(&dc_uart_driver);

	if (ret)
		return ret;
	ret = platform_driver_register(&dc_platform_driver);
	if (ret)
		uart_unregister_driver(&dc_uart_driver);
	return ret;
}
module_init(dc_init);

static void __exit dc_exit(void)
{
	platform_driver_unregister(&dc_platform_driver);
	uart_unregister_driver(&dc_uart_driver);
}
module_exit(dc_exit);

#ifdef CONFIG_SERIAL_EARLYCON
static void dc_early_write(struct console *con, const char *s, unsigned int n)
{
	struct earlycon_device *dev = con->data;

	uart_console_write(&dev->port, s, n, dc_console_putchar);
}

static int __init dc_early_setup(struct earlycon_device *dev, const char *opt)
{
	if (!dev->port.membase)
		return -ENODEV;
	dev->con->write = dc_early_write;
	return 0;
}
OF_EARLYCON_DECLARE(dockchannel, "apple,dockchannel-uart", dc_early_setup);
#endif

MODULE_DESCRIPTION("Apple dockchannel UART console");
MODULE_LICENSE("GPL");
