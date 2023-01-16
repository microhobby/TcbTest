using System.Device.Gpio;
using System.Device.Gpio.Drivers;

// See https://aka.ms/new-console-template for more information
Console.WriteLine("Hello Torizon from actions!");

var gpioDriver = new LibGpiodDriver();
var gpioController = new GpioController(PinNumberingScheme.Logical, gpioDriver);
var gpioPin = 0;
var pinMode = PinMode.Output;
gpioController.OpenPin(gpioPin, pinMode);

while (true) {
    gpioController.Write(gpioPin, PinValue.High);
    Console.WriteLine("LED ON");
    Thread.Sleep(500);
    
    gpioController.Write(gpioPin, PinValue.Low);
    Console.WriteLine("LED OFF");
    Thread.Sleep(500);
}
