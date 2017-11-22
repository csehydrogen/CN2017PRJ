#include <wiringPi.h>
#include <unistd.h>
#define GPIO_RESET_PIN 7
int main() {
	 wiringPiSetup();
	  pinMode(GPIO_RESET_PIN, OUTPUT);
	   digitalWrite(GPIO_RESET_PIN, HIGH);
		 sleep(5);
		  digitalWrite(GPIO_RESET_PIN, LOW);
		   return;
}

